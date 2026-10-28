from pathlib import Path
from fontTools.ttLib import TTFont

Root = Path(__file__).resolve().parent.parent
Source = Root / "assets" / "Fonts"
Targets = {
    "splatoon1Common.woff2": "SplatoonCommon.ttf",
    "splatoon1Symbol.woff2": "SplatoonSymbol.ttf",
    "splatoon1Cjk.woff2": "SplatoonCjk.ttf",
    "splatoon1JpKana.woff2": "SplatoonKana.ttf",
    "splatoon1ZhL1.woff2": "SplatoonZhL1.ttf",
    "splatoon1ZhL2.woff2": "SplatoonZhL2.ttf",
}
for InputName, OutputName in Targets.items():
    Font = TTFont(Source / InputName)
    Font.flavor = None
    Font.save(Source / OutputName)
    Font.close()
    print(OutputName)
