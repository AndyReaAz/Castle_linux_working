// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/gpio/consumer.h>
#include <linux/delay.h>
#include <linux/of.h>
#include <linux/of_graph.h>
#include <linux/slab.h>
#include <sound/soc.h>
#include <linux/errno.h>

/*
 * Exported from atmel_ssc_dai.c
 */
extern int atmel_ssc_send_word(struct snd_soc_dai *dai, u32 word);
extern int atmel_ssc_transfer_frame(struct snd_soc_dai *dai, u32 command,
				    unsigned int command_words,
				    unsigned int response_words,
				    u32 *response_status);
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

#define ADS131A_REG_ID_MSB    0x00
#define ADS131A_REG_A_SYS_CFG 0x0b
#define ADS131A_REG_CLK1      0x0d
#define ADS131A_REG_CLK2      0x0e
#define ADS131A_REG_ADC_ENA   0x0f

/*
 * NextGen supplies 24.576 MHz on XTAL1/CLKIN and operates the ADS131A in
 * synchronous-master mode. CLK1 /2 therefore gives a 12.288 MHz ICLK/SCLK.
 *
 * High-resolution fMOD must not exceed 4.25 MHz. Use ICLK /4 so fMOD is
 * 3.072 MHz, then select the OSR required for each PCM sample rate.
 */
#define ADS131A_CLK1_CLKIN_DIV2 0x02
#define ADS131A_CLK2_ICLK_DIV4  0x40
#define ADS131A_CLK2_OSR_32     0x0f
#define ADS131A_CLK2_OSR_64     0x0d
#define ADS131A_CLK2_OSR_192    0x0a

#define ADS131A_NUM_CH_A02       0x02
#define ADS131A_NUM_CH_A04       0x04

#define ADS131A_RATES (SNDRV_PCM_RATE_96000 | SNDRV_PCM_RATE_48000 | SNDRV_PCM_RATE_16000)
#define ADS131A_FORMATS (SNDRV_PCM_FMTBIT_S32_LE | SNDRV_PCM_FMTBIT_S24_LE)

struct ads131a_priv {
	struct platform_device *plat;
	struct device *dev;
	struct gpio_desc *resetgpio;
	int ssc_id;
	u8 num_channels;
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

static int ads131a_parse_reg_response(struct snd_soc_dai *cpu_dai,
				      u8 addr, u32 response, u8 *value)
{
	u8 response_addr = (response >> 16) & 0xff;
	u8 response_value = (response >> 8) & 0xff;
	u8 expected_addr = 0x20 | (addr & 0x1f);

	if (response_addr != expected_addr) {
		dev_err(cpu_dai->dev,
			"ADS131A register response mismatch: reg=0x%02x response=0x%06x\n",
			addr, response);
		return -EIO;
	}

	if (value)
		*value = response_value;

	return 0;
}

static int ads131a_send_cmd(struct snd_soc_dai *cpu_dai, u32 cmd,
			    unsigned int frame_words)
{
	u32 response;
	int ret;

	dev_dbg(cpu_dai->dev, "ADS131A CMD 0x%08x frame_words=%u\n",
		cmd, frame_words);

	ret = atmel_ssc_transfer_frame(cpu_dai, cmd, frame_words,
				      frame_words, &response);
	if (ret) {
		dev_err(cpu_dai->dev,
			"failed to send ADS131A cmd 0x%08x (%d)\n", cmd, ret);
		return ret;
	}

	if (cmd != ADS131A_CMD_NULL &&
	    (response & 0xffff00) != (cmd & 0xffff00)) {
		dev_err(cpu_dai->dev,
			"ADS131A cmd 0x%08x response mismatch: 0x%06x\n",
			cmd, response);
		return -EIO;
	}

	return 0;
}

static int ads131a_read_reg(struct snd_soc_dai *cpu_dai, u8 addr,
			    unsigned int frame_words, u8 *value)
{
	u32 response;
	int ret;

	ret = atmel_ssc_transfer_frame(cpu_dai,
				      0x200000 | ((addr & 0x1f) << 16),
				      frame_words, frame_words, &response);
	if (ret)
		return ret;

	return ads131a_parse_reg_response(cpu_dai, addr, response, value);
}

static int ads131a_write_reg(struct snd_soc_dai *cpu_dai, u8 addr, u8 value,
			     unsigned int command_words,
			     unsigned int response_words)
{
	u32 response;
	u8 readback;
	int ret;

	ret = atmel_ssc_transfer_frame(cpu_dai,
				      0x400000 | ((addr & 0x1f) << 16) |
				      ((u32)value << 8),
				      command_words, response_words, &response);
	if (ret)
		return ret;

	ret = ads131a_parse_reg_response(cpu_dai, addr, response, &readback);
	if (ret)
		return ret;

	if (readback != value) {
		dev_err(cpu_dai->dev,
			"ADS131A reg 0x%02x verify failed: wrote 0x%02x read 0x%02x\n",
			addr, value, readback);
		return -EIO;
	}

	return 0;
}

static int ads131a_configure(struct snd_soc_dai *cpu_dai,
			     struct snd_pcm_hw_params *params,
			     struct ads131a_priv *priv)
{
	unsigned int frame_words = 1;
	unsigned int data_frame_words;
	u8 adc_ena;
	u8 clk2;
	u8 id_msb;
	int ret;

	atmel_ssc_get_going_config(cpu_dai);

	ret = atmel_ssc_transfer_frame(cpu_dai, ADS131A_CMD_NULL,
				      frame_words, frame_words, NULL);
	if (ret)
		return ret;

	ret = ads131a_send_cmd(cpu_dai, ADS131A_CMD_UNLOCK, frame_words);
	if (ret)
		return ret;

	ret = ads131a_read_reg(cpu_dai, ADS131A_REG_ID_MSB,
			       frame_words, &id_msb);
	if (ret)
		return ret;

	if (id_msb != ADS131A_NUM_CH_A02 && id_msb != ADS131A_NUM_CH_A04) {
		dev_err(priv->dev, "unsupported ADS131A channel ID 0x%02x\n",
			id_msb);
		return -ENODEV;
	}
	priv->num_channels = id_msb;

	/*
	 * ALSA channels are transport words here, including the leading status
	 * word: sound uses 3 words (status + 2 ADC channels), vibration uses
	 * 5 words per converter (status + 4 ADC channels).
	 *
	 * Existing NextGen hardware deliberately uses ADC_ENA=0x03 for the
	 * deployed status+2 path, including on an A04. Preserve that behaviour.
	 */
	switch (params_channels(params)) {
	case 3:
		adc_ena = 0x03;
		data_frame_words = 3;
		break;
	case 5:
		if (priv->num_channels != ADS131A_NUM_CH_A04) {
			dev_err(priv->dev,
				"5-word capture requires ADS131A04, detected ADS131A%02u\n",
				priv->num_channels);
			return -EINVAL;
		}
		adc_ena = 0x0f;
		data_frame_words = 5;
		break;
	default:
		dev_err(priv->dev, "unsupported ADS131A transport width %u\n",
			params_channels(params));
		return -EINVAL;
	}

	dev_info(priv->dev, "detected ADS131A%02u, transport=%u words\n",
		 priv->num_channels, data_frame_words);

	ret = ads131a_write_reg(cpu_dai, ADS131A_REG_A_SYS_CFG, 0x78,
				frame_words, frame_words);
	if (ret)
		return ret;

	/*
	 * Keep fMOD at 3.072 MHz for every supported output rate:
	 *
	 *   CLKIN  = 24.576 MHz
	 *   CLK1   = /2  -> ICLK/SCLK = 12.288 MHz
	 *   CLK2   = /4  -> fMOD      =  3.072 MHz
	 *
	 * The CLK2 OSR then selects 96/48/16 kHz without changing the
	 * modulator clock.
	 */
	switch (params_rate(params)) {
	case 96000:
		clk2 = ADS131A_CLK2_ICLK_DIV4 | ADS131A_CLK2_OSR_32;
		break;
	case 48000:
		clk2 = ADS131A_CLK2_ICLK_DIV4 | ADS131A_CLK2_OSR_64;
		break;
	case 16000:
		clk2 = ADS131A_CLK2_ICLK_DIV4 | ADS131A_CLK2_OSR_192;
		break;
	default:
		return -EINVAL;
	}

	ret = ads131a_write_reg(cpu_dai, ADS131A_REG_CLK2, clk2,
				frame_words, frame_words);
	if (ret)
		return ret;

	/*
	 * ADC_ENA changes the dynamic-frame size. Complete the one-word command
	 * frame, then clock a complete response frame using the new width so the
	 * following WAKEUP starts on a real frame boundary.
	 */
	ret = ads131a_write_reg(cpu_dai, ADS131A_REG_ADC_ENA, adc_ena,
				frame_words, data_frame_words);
	if (ret)
		return ret;
	frame_words = data_frame_words;

	ret = ads131a_send_cmd(cpu_dai, ADS131A_CMD_WAKEUP, frame_words);
	if (ret)
		return ret;

	/*
	 * This must remain the final register write. In synchronous-master mode
	 * CLK1 /2 makes the ADC drive SCLK at 12.288 MHz, after which the current
	 * command path cannot reliably perform further configuration writes.
	 */
	ret = ads131a_write_reg(cpu_dai, ADS131A_REG_CLK1,
				ADS131A_CLK1_CLKIN_DIV2,
				frame_words, frame_words);
	if (ret)
		return ret;

	dev_info(priv->dev,
		 "configured CLK1=0x%02x CLK2=0x%02x ADC_ENA=0x%02x fMOD=3.072MHz\n",
		 ADS131A_CLK1_CLKIN_DIV2, clk2, adc_ena);

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
	ret = ads131a_configure(cpu_dai, params, priv);
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
