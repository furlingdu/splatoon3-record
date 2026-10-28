package cn.miodu.splatoon3record

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager

object MobileAudioDevices {
  fun List(ContextValue: Context): List<Map<String, Any>> {
    val Manager = ContextValue.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val Result = ArrayList<Map<String, Any>>()
    for (Device in Manager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
      val Name = Device.productName.toString().ifEmpty { DeviceName(Device.type) }
      val External = Device.type == AudioDeviceInfo.TYPE_USB_DEVICE || Device.type == AudioDeviceInfo.TYPE_USB_HEADSET
      Result.add(mapOf("id" to Device.id.toString(), "name" to Name, "kind" to "audio", "external" to External))
    }
    return Result
  }

  fun Find(ContextValue: Context, DeviceId: String): AudioDeviceInfo? {
    if (DeviceId.isEmpty()) return null
    val Manager = ContextValue.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    return Manager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id.toString() == DeviceId }
  }

  private fun DeviceName(Type: Int): String = when (Type) {
    AudioDeviceInfo.TYPE_USB_DEVICE -> "USB 音频"
    AudioDeviceInfo.TYPE_USB_HEADSET -> "USB 耳机"
    AudioDeviceInfo.TYPE_BUILTIN_MIC -> "内置麦克风"
    AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "蓝牙麦克风"
    else -> "音频输入"
  }
}
