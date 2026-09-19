// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.graphics.Color
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
class AppearanceTest {
    private fun inspect(dark: Boolean) {
        ReceiverState.status = "已停止"
        ReceiverState.connectedPeers = emptySet()
        org.robolectric.RuntimeEnvironment.getApplication().getSharedPreferences("devices", 0).edit().putString("deviceName", "小米 13").commit()
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()
        val ui = Ui(activity)
        assertEquals(dark, ui.dark)
        assertEquals(Color.parseColor(if (dark) "#151F2B" else "#F0F4F6"), ui.background)
        fun buttons(view: View): List<Button> = if (view is Button) listOf(view) else if (view is ViewGroup) (0 until view.childCount).flatMap { buttons(view.getChildAt(it)) } else emptyList()
        val controls = buttons(activity.window.decorView)
        assertTrue(controls.any { it.text == "开启接收" })
        assertTrue(controls.any { it.text == "启用输入法" })
        assertFalse(controls.any { it.text == "选择输入法" })
        assertFalse(controls.any { it.text.toString().contains("备用配对") })
        System.getenv("WRI_UI_PREVIEWS")?.let { directory ->
            val view = activity.window.decorView
            view.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(2400, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, 1080, 2400)
            val bitmap = android.graphics.Bitmap.createBitmap(1080, 2400, android.graphics.Bitmap.Config.ARGB_8888)
            view.draw(android.graphics.Canvas(bitmap))
            java.io.File(directory).mkdirs()
            java.io.File(directory, if (dark) "android-dark.png" else "android-light.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        }
        controller.pause().stop().destroy()
    }
    @Test fun selectedImeDoesNotOfferSetupAgain() {
        val app = org.robolectric.RuntimeEnvironment.getApplication()
        android.provider.Settings.Secure.putString(app.contentResolver, android.provider.Settings.Secure.DEFAULT_INPUT_METHOD, "dev.wifiremote/.RemoteIme")
        ReceiverState.status = "接收中"
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        fun labels(view: View): List<String> = if (view is android.widget.TextView) listOf(view.text.toString()) else if (view is ViewGroup) (0 until view.childCount).flatMap { labels(view.getChildAt(it)) } else emptyList()
        val texts = labels(controller.get().window.decorView)
        assertTrue(texts.contains("已就绪  ✓"))
        assertFalse(texts.contains("启用输入法"))
        assertFalse(texts.contains("选择输入法"))
        assertTrue(texts.contains("显示配对二维码"))
        assertFalse(texts.contains("开启接收"))
        controller.pause().stop().destroy()
        ReceiverState.status = "已停止"
    }
    @Test @Config(qualifiers = "w360dp-h800dp-notnight-xxhdpi") fun lightSystemAppearance() = inspect(false)
    @Test @Config(qualifiers = "w360dp-h800dp-night-xxhdpi") fun darkSystemAppearance() = inspect(true)
}
