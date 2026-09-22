// sound/soc/codecs/ads131a-codec.c

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <sound/soc.h>

#define ADS131A_RATES   SNDRV_PCM_RATE_96000
#define ADS131A_FORMATS (SNDRV_PCM_FMTBIT_S32_LE | SNDRV_PCM_FMTBIT_S24_LE)

static int ads131a_codec_set_tdm_slot(struct snd_soc_dai *dai,
                                      unsigned int tx_mask,
                                      unsigned int rx_mask,
                                      int slots,
                                      int slot_width)
{
        dev_info(dai->dev, "TDM slots=%d width=%d tx=%x rx=%x\n",
                 slots, slot_width, tx_mask, rx_mask);
        return 0;
}

static const struct snd_soc_dai_ops ads131a_codec_dai_ops = {
        .set_tdm_slot = ads131a_codec_set_tdm_slot,
};

static struct snd_soc_dai_driver ads131a_codec_dai = {
        .name = "ads131a",
        .capture = {
                .stream_name = "Capture",
                .channels_min = 2,
                .channels_max = 3,
                .rates = ADS131A_RATES,
                .formats = ADS131A_FORMATS,
        },
        .ops = &ads131a_codec_dai_ops,
};

static const struct snd_soc_component_driver ads131a_codec_component = {
        .name = "ads131a-codec",
};

static int ads131a_codec_probe(struct platform_device *pdev)
{
        dev_info(&pdev->dev, "register ADS131A ASoC codec\n");

        return devm_snd_soc_register_component(&pdev->dev,
                                               &ads131a_codec_component,
                                               &ads131a_codec_dai,
                                               1);
}

static const struct of_device_id ads131a_codec_of_match[] = {
        { .compatible = "nextgen,ads131a-codec" },
        { }
};
MODULE_DEVICE_TABLE(of, ads131a_codec_of_match);

static struct platform_driver ads131a_codec_driver = {
        .driver = {
                .name = "ads131a-codec",
                .of_match_table = ads131a_codec_of_match,
        },
        .probe = ads131a_codec_probe,
};

module_platform_driver(ads131a_codec_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ADS131A ASoC codec component");
