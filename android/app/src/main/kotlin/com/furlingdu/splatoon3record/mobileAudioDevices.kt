package com.furlingdu.splatoon3record

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager

object MobileAudioDevices {
  fun List(ContextValue: Context): List<Map<String, Any>> {
    val Manager = ContextValue.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val Result = ArrayList<Map<String, Any>>()
    for (Device in Manager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
      if (!IsExternal(Device)) continue
      val Name = Device.productName.toString().ifEmpty { DeviceName(Device.type) }
      Result.add(mapOf("id" to Device.id.toString(), "name" to Name, "kind" to "audio", "external" to true))
    }
    return Result
  }

  fun Find(ContextValue: Context, DeviceId: String): AudioDeviceInfo? {
    val Manager = ContextValue.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val Devices = Manager.getDevices(AudioManager.GET_DEVICES_INPUTS).filter { IsExternal(it) }
    if (DeviceId.isEmpty()) return Devices.firstOrNull()
    return Devices.firstOrNull { it.id.toString() == DeviceId }
  }

  fun IsExternal(Device: AudioDeviceInfo): Boolean {
    return Device.type == AudioDeviceInfo.TYPE_USB_DEVICE || Device.type == AudioDeviceInfo.TYPE_USB_HEADSET
  }

  private fun DeviceName(Type: Int): String = when (Type) {
    AudioDeviceInfo.TYPE_USB_DEVICE -> "USB 音频"
    AudioDeviceInfo.TYPE_USB_HEADSET -> "USB 耳机"
    else -> "采集卡音频"
  }
}
