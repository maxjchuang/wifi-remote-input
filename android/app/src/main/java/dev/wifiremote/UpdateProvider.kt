// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.content.*
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns

/** One read-only APK; never accepts filesystem paths from a URI. */
class UpdateProvider : ContentProvider() {
    companion object { fun uri(context: Context): Uri = Uri.parse("content://${context.packageName}.update/package.apk") }
    override fun onCreate() = true
    private fun check(uri: Uri) { require(uri == uri(context!!)) }
    override fun getType(uri: Uri): String { check(uri); return "application/vnd.android.package-archive" }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        check(uri); require(mode == "r")
        return ParcelFileDescriptor.open(UpdateInbox.file(context!!), ParcelFileDescriptor.MODE_READ_ONLY)
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): MatrixCursor {
        check(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply { addRow(columns.map { if (it == OpenableColumns.DISPLAY_NAME) "WiFiRemoteInput.apk" else if (it == OpenableColumns.SIZE) UpdateInbox.file(context!!).length() else null }) }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
}
