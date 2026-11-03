package pdspike;

// Shell-UID comparison of the two thumbnail sources (measurement only; never
// part of the product). Runs under app_process at UID 2000 and prints aggregate
// timings only: no file name or path leaves this program.
//
//   app_process /system/bin pdspike.Spike /sdcard/DCIM/Camera 512
//
// today: ThumbnailUtils.createImageThumbnail(File, Size, CancellationSignal)
//         (what AndroidThumbSource calls now)
// media: ContentResolver.loadThumbnail(uri, Size, CancellationSignal)
//         (MediaStore's own cache, after mapping the path to its media id)
//
// Both passes are timed cold, then again warm. The legacy `thumbnails` table's
// row count is read before and after the cold MediaStore pass: a growth is the
// evidence that a cache miss made MediaStore write one.

import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Context;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.media.ThumbnailUtils;
import android.net.Uri;
import android.os.CancellationSignal;
import android.provider.MediaStore;
import android.util.Size;

import java.io.File;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class Spike {
    private static final String PREFIX = "pd-spike-";

    public static void main(String[] args) {
        String folder = args.length > 0 ? args[0] : "/sdcard/DCIM/Camera";
        int size = args.length > 1 ? Integer.parseInt(args[1]) : 512;
        File[] listing = new File(folder).listFiles(
                (dir, name) -> name.startsWith(PREFIX) && name.toLowerCase().endsWith(".jpg"));
        if (listing == null) listing = new File[0];
        Arrays.sort(listing);
        System.out.println("FILES=" + listing.length);
        if (listing.length == 0) return;

        ContentResolver resolver = resolver();
        List<Long> ids = new ArrayList<>();
        if (resolver != null) mapIds(resolver, listing, ids);

        long[] todayCold = new long[listing.length];
        int todayFail = 0;
        for (int i = 0; i < listing.length; i++) {
            long started = System.nanoTime();
            Bitmap bitmap = null;
            try {
                bitmap = ThumbnailUtils.createImageThumbnail(
                        listing[i], new Size(size, size), new CancellationSignal());
            } catch (Throwable failure) {
                todayFail++;
            }
            todayCold[i] = (System.nanoTime() - started) / 1_000_000;
            if (bitmap != null) bitmap.recycle();
        }
        report("today_cold", todayCold, todayFail);

        if (resolver == null || ids.isEmpty()) {
            System.out.println("MEDIASTORE=skipped resolver=" + (resolver != null) + " ids=" + ids.size());
            return;
        }

        Uri thumbs = MediaStore.Images.Thumbnails.EXTERNAL_CONTENT_URI;
        System.out.println("THUMB_ROWS_BEFORE=" + thumbRows(resolver, thumbs));
        long[] mediaCold = new long[ids.size()];
        int mediaFail = 0;
        for (int i = 0; i < ids.size(); i++) {
            Uri uri = ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ids.get(i));
            long started = System.nanoTime();
            Bitmap bitmap = null;
            try {
                bitmap = resolver.loadThumbnail(uri, new Size(size, size), new CancellationSignal());
            } catch (Throwable failure) {
                mediaFail++;
                if (mediaFail == 1) System.out.println("LOAD_THUMB=" + failure.getClass().getSimpleName());
            }
            mediaCold[i] = (System.nanoTime() - started) / 1_000_000;
            if (bitmap != null) bitmap.recycle();
        }
        report("mediastore_cold", mediaCold, mediaFail);
        System.out.println("THUMB_ROWS_AFTER=" + thumbRows(resolver, thumbs));

        long[] todayWarm = new long[listing.length];
        for (int i = 0; i < listing.length; i++) {
            long started = System.nanoTime();
            Bitmap bitmap = null;
            try {
                bitmap = ThumbnailUtils.createImageThumbnail(
                        listing[i], new Size(size, size), new CancellationSignal());
            } catch (Throwable failure) {
                // counted in the cold pass
            }
            todayWarm[i] = (System.nanoTime() - started) / 1_000_000;
            if (bitmap != null) bitmap.recycle();
        }
        report("today_warm", todayWarm, 0);

        long[] mediaWarm = new long[ids.size()];
        for (int i = 0; i < ids.size(); i++) {
            Uri uri = ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ids.get(i));
            long started = System.nanoTime();
            Bitmap bitmap = null;
            try {
                bitmap = resolver.loadThumbnail(uri, new Size(size, size), new CancellationSignal());
            } catch (Throwable failure) {
                // counted in the cold pass
            }
            mediaWarm[i] = (System.nanoTime() - started) / 1_000_000;
            if (bitmap != null) bitmap.recycle();
        }
        report("mediastore_warm", mediaWarm, 0);
    }

    /// The system context without a manifest: the path every app_process shell
    /// tool takes to a ContentResolver at UID 2000.
    private static ContentResolver resolver() {
        try {
            Class<?> threadClass = Class.forName("android.app.ActivityThread");
            Method systemMain = threadClass.getMethod("systemMain");
            Object thread = systemMain.invoke(null);
            Method systemContext = threadClass.getMethod("getSystemContext");
            Context context = (Context) systemContext.invoke(thread);
            System.out.println("RESOLVER=ok");
            return context.getContentResolver();
        } catch (Throwable failure) {
            System.out.println("RESOLVER=blocked " + failure.getClass().getSimpleName());
            return null;
        }
    }

    private static void mapIds(ContentResolver resolver, File[] files, List<Long> ids) {
        String[] projection = {MediaStore.MediaColumns._ID};
        int dataDenied = 0;
        for (File file : files) {
            try (Cursor cursor = resolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    projection, MediaStore.MediaColumns.DATA + "=?",
                    new String[]{file.getAbsolutePath()}, null)) {
                if (cursor != null && cursor.moveToFirst()) {
                    ids.add(cursor.getLong(0));
                }
            } catch (Throwable failure) {
                dataDenied++;
                if (dataDenied == 1) System.out.println("MEDIA_QUERY=blocked " + failure.getClass().getSimpleName());
                break;
            }
        }
        System.out.println("MEDIA_ROWS=" + ids.size() + " OF=" + files.length);
    }

    private static long thumbRows(ContentResolver resolver, Uri uri) {
        try (Cursor cursor = resolver.query(uri, new String[]{"_id"}, null, null, null)) {
            return cursor == null ? -1 : cursor.getCount();
        } catch (Throwable failure) {
            System.out.println("THUMB_TABLE=blocked " + failure.getClass().getSimpleName());
            return -1;
        }
    }

    private static void report(String label, long[] samples, int failures) {
        long[] sorted = samples.clone();
        Arrays.sort(sorted);
        System.out.println(label + " N=" + samples.length + " FAIL=" + failures
                + " P50=" + percentile(sorted, 50) + " P95=" + percentile(sorted, 95)
                + " MIN=" + (sorted.length == 0 ? -1 : sorted[0])
                + " MAX=" + (sorted.length == 0 ? -1 : sorted[sorted.length - 1]));
    }

    private static long percentile(long[] sorted, int percent) {
        if (sorted.length == 0) return -1;
        int index = (int) Math.ceil(sorted.length * percent / 100.0) - 1;
        return sorted[Math.max(0, Math.min(index, sorted.length - 1))];
    }
}
