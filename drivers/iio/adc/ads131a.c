// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/gpio/consumer.h>
#include <linux/of.h>
#include <linux/of_graph.h>
#include <linux/slab.h>
#include <sound/soc.h>
#include <linux/errno.h>

/*
 * Exported from atmel_ssc_dai.c
 */
extern int atmel_ssc_send_word(struct snd_soc_dai *dai, u32 word);
extern void atmel_ssc_get_going_config(struct snd_soc_dai *dai);
extern void atmel_ssc_config_done(struct snd_soc_dai *dai);
/*
 * ADS131A commands
 * (update these for your exact device variant)
 */
#define ADS131A_CMD_NULL 0x00000000
#define ADS131A_CMD_RESET 0x00001100
#define ADS131A_CMD_STANDBY 0x00002200
#define ADS131A_CMD_WAKEUP 0x00003300
#define ADS131A_CMD_LOCK 0x00055500
#define ADS131A_CMD_UNLOCK 0x00065500
#define ADS131A_CMD_START 0x00008800
#define ADS131A_CMD_STOP 0x0000AA00

#define ADS131A_RATES (SNDRV_PCM_RATE_96000 | SNDRV_PCM_RATE_48000 | SNDRV_PCM_RATE_16000)
#define ADS131A_FORMATS (SNDRV_PCM_FMTBIT_S32_LE | SNDRV_PCM_FMTBIT_S24_LE)

struct ads131a_priv {
	struct platform_device *plat;
	struct device *dev;
	struct gpio_desc *resetgpio;
	int ssc_id;
	bool initialised;
};

static int ads131a_get_ssc_id(struct device *dev)
{
	struct device_node *endpoint;
	struct device_node *ssc_np;
	int id;

	endpoint = of_graph_get_next_endpoint(dev->of_node, NULL);
	if (!endpoint)
		return -ENODEV;

	ssc_np = of_graph_get_remote_port_parent(endpoint);
	of_node_put(endpoint);
	if (!ssc_np)
		return -ENODEV;

	id = of_alias_get_id(ssc_np, "ssc");
	of_node_put(ssc_np);

	return id;
}

static int ads131a_send_cmd(struct snd_soc_dai *cpu_dai, u32 cmd)
{
	int ret;

	dev_dbg(cpu_dai->dev, "ADS131A CMD 0x%08x\n", cmd);

	ret = atmel_ssc_send_word(cpu_dai, cmd);
	if (ret)
		dev_err(cpu_dai->dev,
			"failed to send ADS131A cmd 0x%08x (%d)\n", cmd, ret);

	return ret;
}
static int ads131a_write_reg(struct snd_soc_dai *cpu_dai, u32 Addr, u32 Value)
{
	return ads131a_send_cmd(cpu_dai, 0x400000 | ((Addr & 0x1f) << 16) |
						 ((Value & 0xff) << 8));
}

static int ads131a_configure(struct snd_soc_dai *cpu_dai,
			     struct snd_pcm_hw_params *params)
{
	int ret;

	atmel_ssc_get_going_config(cpu_dai);

	ret = ads131a_send_cmd(cpu_dai, ADS131A_CMD_NULL);
	if (ret)
		return ret;
	ret = ads131a_send_cmd(cpu_dai, ADS131A_CMD_UNLOCK);
	if (ret)
		return ret;

#define ADC_A_SYS_CFG 0x0b
#define ADC_CLK1 0x0d
#define ADC_CLK2 0x0e
#define ADC_ENA 0x0f

	ads131a_write_reg(cpu_dai, ADC_A_SYS_CFG,
			  0x78); // high res mode, reserved, vref 4v, int
	// ref en, fault threshold 0
	if (params_rate(params) == 96000)
		ads131a_write_reg(
			cpu_dai, ADC_CLK2,
			0x2d); // 96kHz sample rate (from 24.xxxMHz master clock  )	/ 64
	else if (params_rate(params) == 48000)
		ads131a_write_reg(
			cpu_dai, ADC_CLK2,
			0x2b); // 48kHz sample rate (from 24.xxxMHz master clock  )	/ 128
	else if (params_rate(params) == 16000)
		ads131a_write_reg(
			cpu_dai, ADC_CLK2,
			0x27); // 16kHz sample rate (from 24.xxxMHz master clock  )	/ 384
	else
		return -EINVAL;

	if (params_channels(params) == 2 || params_channels(params) == 3)
		ads131a_write_reg(cpu_dai, ADC_ENA,				  0x03); // Enable first 2 channels only
	else if (params_channels(params) == 4 || params_channels(params) == 5)
		ads131a_write_reg(cpu_dai, ADC_ENA, 0x0f); // Enable all 4 channels */
	else
		return -EINVAL;

	ret = ads131a_send_cmd(cpu_dai, 0x003300); // Wake up
	// this speed up has to be the last write as we can't write to the ADC when
	// it's running at 12MHz clock out
	ads131a_write_reg(cpu_dai, ADC_CLK1, 0x02); // input clock / 2

	/*
         * Start conversions
         */
	//ret = ads131a_send_cmd(cpu_dai, ADS131A_CMD_START);
	if (ret)
		return ret;
	atmel_ssc_config_done(cpu_dai);
	return 0;
}

static int ads131a_hw_params(struct snd_pcm_substream *substream,
			     struct snd_pcm_hw_params *params,
			     struct snd_soc_dai *dai)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct snd_soc_dai *cpu_dai = snd_soc_rtd_to_cpu(rtd, 0);
	struct ads131a_priv *priv = dev_get_drvdata(dai->dev);
	int ret;

	if (!priv)
		return -ENODEV;

	if (priv->initialised)
		return 0;
	/* No hardware constraints enforced here (TDM handled by SSC) */
	dev_info(
		dai->dev,
		"%s rate=%u channels=%u period=%u periods=%u buffer=%u bytes=%u\n",
		__func__, params_rate(params), params_channels(params),
		params_period_size(params), params_periods(params),
		params_buffer_size(params), params_buffer_bytes(params));

	/*
         * Configure this ADS131A instance before capture starts.
         */
	ret = ads131a_configure(cpu_dai, params);
	if (!ret)
		priv->initialised = true;

	return ret;
}

static int ads131a_set_tdm_slot(struct snd_soc_dai *dai, unsigned int tx_mask,
				unsigned int rx_mask, int slots, int slot_width)
{
	dev_info(dai->dev, "set_tdm_slot tx=%x rx=%x slots=%d width=%d\n",
		 tx_mask, rx_mask, slots, slot_width);

	return 0;
}

static const struct snd_soc_dai_ops ads131a_dai_ops = {
	.hw_params = ads131a_hw_params,
	.set_tdm_slot = ads131a_set_tdm_slot,
};

static struct snd_soc_dai_driver ads131a_dai = {
        .name = "ads131a",

        .capture = {
                .stream_name  = "Capture",
                .channels_min = 3,
                .channels_max = 5,
                .rates         = ADS131A_RATES,
                .formats       = ADS131A_FORMATS,
        },

        .ops = &ads131a_dai_ops,
};

static const struct snd_soc_component_driver ads131a_component = {
	.name = "ads131a",
};

static const struct of_device_id ads131a_of_match[] = {
	{ .compatible = "ti,ads131a" },
	{}
};

MODULE_DEVICE_TABLE(of, ads131a_of_match);

static int ads131a_probe(struct platform_device *pdev)
{
	struct ads131a_priv *priv;
	int ret;

	priv = devm_kzalloc(&pdev->dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->plat = pdev;
	priv->dev = &pdev->dev;
	priv->ssc_id = ads131a_get_ssc_id(&pdev->dev);
	if (priv->ssc_id < 0) {
		dev_err(&pdev->dev,
			"failed to determine connected SSC alias (%d)\n",
			priv->ssc_id);
		return priv->ssc_id;
	}

	platform_set_drvdata(pdev, priv);

	/*
	 * Both ADCs share one reset signal.  Only the ADC connected to
	 * the DT "ssc0" alias owns and drives that GPIO.  The SSC1-linked
	 * instance must not request the same line a second time.
	 */
	if (priv->ssc_id == 0) {
		priv->resetgpio =
			devm_gpiod_get(&pdev->dev, "codecreset",
					GPIOD_OUT_HIGH);
		if (IS_ERR(priv->resetgpio)) {
			ret = PTR_ERR(priv->resetgpio);
			dev_err(&pdev->dev,
				"failed to request shared reset GPIO (%d)\n",
				ret);
			return ret;
		}

		gpiod_set_value_cansleep(priv->resetgpio, 0);
		msleep(10);
		gpiod_set_value_cansleep(priv->resetgpio, 1);
		msleep(10);
		gpiod_set_value_cansleep(priv->resetgpio, 0);
	} else if (priv->ssc_id != 1) {
		dev_err(&pdev->dev, "unsupported SSC alias ssc%d\n",
			priv->ssc_id);
		return -EINVAL;
	}

	priv->initialised = false;

	ret = devm_snd_soc_register_component(&pdev->dev,
					      &ads131a_component,
					      &ads131a_dai, 1);
	if (ret)
		return ret;

	dev_info(&pdev->dev, "probed on ssc%d%s\n", priv->ssc_id,
		 priv->ssc_id == 0 ? " (shared reset owner)" : "");

	return 0;
}

static struct platform_driver ads131a_driver = {
        .driver = {
                .name = "ads131a",
                .of_match_table = ads131a_of_match,
        },
        .probe = ads131a_probe,
};

module_platform_driver(ads131a_driver);

MODULE_AUTHOR("Castle");
MODULE_DESCRIPTION("ADS131A ASoC codec");
MODULE_LICENSE("GPL");
