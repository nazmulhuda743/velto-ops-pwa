package app.velto.ops;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.os.Build;
import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Task-alert channel with a long, strong vibration pattern. Created
        // natively because the Capacitor JS plugin can't set custom patterns.
        // Channels are immutable once created, so pattern changes need a new id.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = getSystemService(NotificationManager.class);
            NotificationChannel ch = new NotificationChannel(
                "velto_tasks_v3", "Task alerts", NotificationManager.IMPORTANCE_HIGH);
            ch.setDescription("New tasks and reminders");
            ch.enableVibration(true);
            // ~2.6s: three strong pulses then a long closing buzz.
            ch.setVibrationPattern(new long[]{0, 600, 250, 600, 250, 900});
            ch.enableLights(true);
            nm.createNotificationChannel(ch);
        }
    }
}
