// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import android.graphics.drawable.RippleDrawable
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.content.res.ColorStateList
import android.widget.*

internal class Ui(val context: Context) {
    val dark = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    val background = Color.parseColor(if (dark) "#151F2B" else "#F0F4F6")
    val surface = Color.parseColor(if (dark) "#1E2C3B" else "#FFFFFF")
    val ink = Color.parseColor(if (dark) "#EEF5FB" else "#192D39")
    val secondary = Color.parseColor(if (dark) "#A8B8C8" else "#526875")
    val accent = Color.parseColor(if (dark) "#73E4CD" else "#087C69")
    fun dp(value: Int) = (value * context.resources.displayMetrics.density).toInt()
    fun shape(color: Int, radius: Int = 20) = GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() }
    fun label(value: String, size: Float = 14f, muted: Boolean = false) = TextView(context).apply {
        text = value; textSize = size; setTextColor(if (muted) secondary else ink)
        setPadding(0, dp(5), 0, dp(5)); setLineSpacing(dp(3).toFloat(), 1f)
    }
    fun column(padding: Int = 20) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL; setPadding(dp(padding), dp(padding), dp(padding), dp(padding))
    }
    fun card() = column().apply {
        background = shape(surface)
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(16) }
    }
    fun button(label: String, primary: Boolean = false, action: () -> Unit) = Button(context).apply {
        text = label; isAllCaps = false; textSize = 15f; minHeight = dp(48)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(if (primary) (if (dark) Color.parseColor("#102D29") else Color.WHITE) else accent)
        backgroundTintList = null
        background = RippleDrawable(ColorStateList.valueOf(if (dark) 0x3373E4CD else 0x22087C69), shape(if (primary) accent else surface, 14), null)
        stateListAnimator = null
        setPadding(dp(16), dp(12), dp(16), dp(12))
        setOnClickListener { action() }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) }
    }
    fun orbit(connected: Boolean) = object : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        init { layoutParams = LinearLayout.LayoutParams(-1, dp(150)); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val x = width / 2f; val y = height / 2f
            paint.style = Paint.Style.STROKE; paint.strokeWidth = dp(1).toFloat()
            paint.color = accent; paint.alpha = if (connected) 65 else 35
            canvas.drawCircle(x, y, dp(60).toFloat(), paint)
            canvas.drawCircle(x, y, dp(44).toFloat(), paint)
            paint.alpha = 255; paint.strokeWidth = dp(2).toFloat()
            canvas.drawRoundRect(x-dp(22), y-dp(14), x+dp(22), y+dp(14), dp(4).toFloat(), dp(4).toFloat(), paint)
            paint.style = Paint.Style.FILL
            for (row in 0..1) for (col in 0..4) canvas.drawCircle(x+dp((col-2)*7), y+dp(row*6-6), dp(1).toFloat(), paint)
            canvas.drawRoundRect(x-dp(11), y+dp(7), x+dp(11), y+dp(9), 1f, 1f, paint)
        }
    }

}
