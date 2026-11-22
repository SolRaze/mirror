// Extend on folio: shows the Mac's virtual display and sends touches back.
// Connects to 127.0.0.1:54400, which `adb reverse` maps to the Mac. Wire format
// is documented at the top of mac/extend.swift; both ends must change together.
package local.sol.extend;

import android.app.Activity;
import android.graphics.Color;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Bundle;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.FrameLayout;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class Main extends Activity implements SurfaceHolder.Callback {
    static final int PORT = 54400;
    static final byte[] START = {0, 0, 0, 1};

    FrameLayout root;
    SurfaceView view;
    volatile Surface surface;
    volatile Socket socket;
    volatile OutputStream out;
    Thread net;
    final ExecutorService tx = Executors.newSingleThreadExecutor();

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getAttributes().layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        view = new SurfaceView(this);
        root.addView(view, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));
        setContentView(root);
        WindowInsetsController c = getWindow().getInsetsController();
        c.hide(WindowInsets.Type.systemBars());
        c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        view.getHolder().addCallback(this);
        view.setOnTouchListener(this::touch);
    }

    @Override public void surfaceCreated(SurfaceHolder h) {
        surface = h.getSurface();
        net = new Thread(this::run, "net");
        net.start();
    }

    @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int hh) {}

    // Leaving the app closes the socket, which stops capture and encode on the Mac.
    @Override public void surfaceDestroyed(SurfaceHolder h) {
        surface = null;
        closeSocket();
        try { net.join(); } catch (InterruptedException ignored) {}
    }

    void closeSocket() {
        Socket s = socket;
        if (s != null) try { s.close(); } catch (Exception ignored) {}
    }

    void run() {
        while (surface != null) {
            MediaCodec codec = null;
            try (Socket s = new Socket()) {
                s.setTcpNoDelay(true);
                s.connect(new InetSocketAddress("127.0.0.1", PORT), 1000);
                socket = s;
                out = s.getOutputStream();
                DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream(), 1 << 20));
                byte[] config = null;
                while (surface != null) {
                    int type = in.readUnsignedByte();
                    byte[] data = new byte[in.readInt()];
                    in.readFully(data);
                    if (type == 0) {
                        if (Arrays.equals(data, config)) continue;
                        config = data;
                        if (codec != null) codec.release();
                        codec = decoder(data);
                    } else if (codec != null) {
                        int i = codec.dequeueInputBuffer(100_000);
                        if (i < 0) continue;
                        codec.getInputBuffer(i).put(data);
                        codec.queueInputBuffer(i, 0, data.length, System.nanoTime() / 1000, 0);
                    }
                }
            } catch (Exception e) {
                // Mac not running or adb reverse not set yet: retry.
            } finally {
                socket = null;
                out = null;
                if (codec != null) codec.release();
            }
            if (surface != null) try { Thread.sleep(500); } catch (InterruptedException ignored) {}
        }
    }

    MediaCodec decoder(byte[] config) throws Exception {
        ByteBuffer b = ByteBuffer.wrap(config);
        int w = b.getShort() & 0xffff, h = b.getShort() & 0xffff, spsLen = b.getShort() & 0xffff;
        byte[] sps = new byte[spsLen], pps = new byte[b.remaining() - spsLen];
        b.get(sps).get(pps);
        MediaFormat f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h);
        f.setByteBuffer("csd-0", ByteBuffer.wrap(concat(START, sps)));
        f.setByteBuffer("csd-1", ByteBuffer.wrap(concat(START, pps)));
        f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
        f.setInteger(MediaFormat.KEY_PRIORITY, 0);
        MediaCodec codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        codec.configure(f, surface, null, 0);
        codec.start();
        new Thread(() -> drain(codec), "drain").start();
        runOnUiThread(() -> fit(w, h));
        return codec;
    }

    // Renders each decoded frame immediately; exits when the codec is released.
    void drain(MediaCodec codec) {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        try {
            while (true) {
                int i = codec.dequeueOutputBuffer(info, 100_000);
                if (i >= 0) codec.releaseOutputBuffer(i, true);
            }
        } catch (Exception ignored) {}
    }

    void fit(int w, int h) {
        float scale = Math.min(root.getWidth() / (float) w, root.getHeight() / (float) h);
        view.setLayoutParams(new FrameLayout.LayoutParams(Math.round(w * scale), Math.round(h * scale), Gravity.CENTER));
    }

    boolean touch(View v, MotionEvent e) {
        int action;
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: action = 0; break;
            case MotionEvent.ACTION_MOVE: action = 1; break;
            case MotionEvent.ACTION_UP: case MotionEvent.ACTION_CANCEL: action = 2; break;
            default: return true;
        }
        int x = clamp(e.getX() / v.getWidth()), y = clamp(e.getY() / v.getHeight());
        byte[] msg = {(byte) action, (byte) (x >> 8), (byte) x, (byte) (y >> 8), (byte) y};
        tx.execute(() -> {
            OutputStream o = out;
            if (o != null) try { o.write(msg); } catch (Exception ignored) {}
        });
        return true;
    }

    static int clamp(float f) { return Math.round(Math.max(0, Math.min(1, f)) * 65535); }

    static byte[] concat(byte[] a, byte[] b) {
        byte[] r = Arrays.copyOf(a, a.length + b.length);
        System.arraycopy(b, 0, r, a.length, b.length);
        return r;
    }
}
