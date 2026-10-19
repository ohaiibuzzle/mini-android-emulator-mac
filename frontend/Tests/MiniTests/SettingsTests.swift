import Testing
@testable import Mini

@Test func iniSettingReplacesOnlyItsKeys() {
  let text = "hw.keyboard=yes\nhw.lcd.width=1080\nhw.lcd.height = 2400\n"
  let out = Prefs.ini(text, setting: ["hw.lcd.width": "2560", "hw.lcd.height": "1440", "hw.lcd.density": "240"])
  #expect(out == "hw.keyboard=yes\nhw.lcd.width=2560\nhw.lcd.height =1440\nhw.lcd.density=240\n")
  #expect(Prefs.ini(out)["hw.lcd.height"] == "1440")
}

@Test func iniSettingNilRemovesKey() {
  #expect(Prefs.ini("a=1\ndisplay.settings.xml=freeform\nb=2\n", setting: ["display.settings.xml": nil, "c": nil]) == "a=1\nb=2\n")
}

@Test func deviceConfigRoundTrips() {
  #expect(DeviceConfig.megabytes("2G") == 2048 && DeviceConfig.megabytes("1536M") == 1536 && DeviceConfig.megabytes("3072") == 3072)
  #expect(DeviceConfig.megabytes("6442450944", bare: 1) == 6144 && DeviceConfig.megabytes("6G", bare: 1) == 6144)
  var c = DeviceConfig()
  c.size = DisplaySize.presets[2].1
  c.ramMB = 4096
  c.storageMB = 16384
  c.refreshHz = 120
  c.freeform = true
  let text = Prefs.ini("image.sysdir.1=\(BaseImage.sysdir)\n", setting: c.values)
  #expect(DeviceConfig(Prefs.ini(text)) == c)
  #expect(c.valid)
  c.storageMB = 1024
  #expect(!c.valid)
  #expect(GSIImport.sysdir(for: "LineageOS-24.0") == "system-images/android-37.0/gsi_lineageos_24_0/arm64-v8a/")
}
