package app.velto.ops;

import android.content.ContentValues;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Base64;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;

/**
 * Saves a base64 file into the phone's public Downloads folder — the one the
 * Files app shows. Web pages inside the WebView cannot do this themselves
 * (scoped storage), hence this tiny bridge.
 */
@CapacitorPlugin(name = "VeltoSaver")
public class VeltoSaver extends Plugin {

    @PluginMethod
    public void saveToDownloads(PluginCall call) {
        try {
            String name = call.getString("name", "velto.pdf");
            String mime = call.getString("mime", "application/pdf");
            String data = call.getString("data", "");
            byte[] bytes = Base64.decode(data, Base64.DEFAULT);
            String outPath;

            if (Build.VERSION.SDK_INT >= 29) {
                ContentValues v = new ContentValues();
                v.put(MediaStore.Downloads.DISPLAY_NAME, name);
                v.put(MediaStore.Downloads.MIME_TYPE, mime);
                v.put(MediaStore.Downloads.IS_PENDING, 1);
                Uri uri = getContext().getContentResolver()
                        .insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
                if (uri == null) { call.reject("MediaStore insert failed"); return; }
                try (OutputStream os = getContext().getContentResolver().openOutputStream(uri)) {
                    os.write(bytes);
                }
                v.clear();
                v.put(MediaStore.Downloads.IS_PENDING, 0);
                getContext().getContentResolver().update(uri, v, null, null);
                outPath = "Download/" + name;
            } else {
                File dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
                if (!dir.exists()) dir.mkdirs();
                File f = new File(dir, name);
                try (FileOutputStream fo = new FileOutputStream(f)) { fo.write(bytes); }
                outPath = f.getAbsolutePath();
            }

            JSObject ret = new JSObject();
            ret.put("path", outPath);
            call.resolve(ret);
        } catch (Exception e) {
            call.reject(String.valueOf(e));
        }
    }
}
