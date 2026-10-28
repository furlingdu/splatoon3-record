package com.furlingdu.splatoon3record

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

object MobileMediaStore {
  fun SaveVideo(ContextValue: Context, Path: String): Boolean {
    val Source = File(Path)
    if (!Source.exists() || Source.length() <= 0) return false
    return try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        SaveModern(ContextValue, Source)
      } else {
        SaveLegacy(ContextValue, Source)
      }
    } catch (_: Exception) {
      false
    }
  }

  private fun SaveModern(ContextValue: Context, Source: File): Boolean {
    val Values = ContentValues().apply {
      put(MediaStore.Video.Media.DISPLAY_NAME, Source.name)
      put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
      put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Splatoon3 Record")
      put(MediaStore.Video.Media.IS_PENDING, 1)
    }
    val Resolver = ContextValue.contentResolver
    val Uri = Resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, Values) ?: return false
    val Output = Resolver.openOutputStream(Uri) ?: return false
    Source.inputStream().use { Input ->
      Output.use { Target ->
        Input.copyTo(Target)
      }
    }
    Values.clear()
    Values.put(MediaStore.Video.Media.IS_PENDING, 0)
    Resolver.update(Uri, Values, null, null)
    return true
  }

  private fun SaveLegacy(ContextValue: Context, Source: File): Boolean {
    val Folder = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "Splatoon3 Record")
    if (!Folder.exists() && !Folder.mkdirs()) return false
    val Target = File(Folder, Source.name)
    Source.copyTo(Target, overwrite = true)
    MediaScannerConnection.scanFile(ContextValue, arrayOf(Target.absolutePath), arrayOf("video/mp4"), null)
    return true
  }
}
