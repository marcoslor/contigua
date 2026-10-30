package dev.pocketdeck.awaretest;

import android.app.Activity;
import android.net.*;
import android.net.wifi.aware.*;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.widget.TextView;
import java.io.*;
import java.net.*;
import java.util.Arrays;

public class Main extends Activity {
    static final String T = "PDAware", NAME = "_pdtest._tcp";
    static final int PORT = 48111, MB = 32;
    TextView view;
    Handler h;
    ConnectivityManager cm;
    boolean requested = false;
    static WifiAwareSession keepSession; static DiscoverySession keepDiscovery; static ConnectivityManager.NetworkCallback keepCb;

    void log(String s) { Log.i(T, s); runOnUiThread(() -> view.append(s + "\n")); }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        view = new TextView(this); setContentView(view);
        if (keepSession != null) { log("recreated; keeping the running session"); return; }
        HandlerThread ht = new HandlerThread("aware"); ht.start(); h = new Handler(ht.getLooper());
        cm = getSystemService(ConnectivityManager.class);
        String lan = getIntent().getStringExtra("lan");
        String psk = getIntent().getStringExtra("psk");
        if (lan != null) { new Thread(() -> bench("lan", null, lan)).start(); return; }
        boolean pubMode = getIntent().getBooleanExtra("pub", false);
        WifiAwareManager m = getSystemService(WifiAwareManager.class);
        log("available=" + m.isAvailable());
        m.attach(new AttachCallback() {
            @Override public void onAttached(WifiAwareSession s) {
                keepSession = s;
                if (pubMode) { publish(s, psk); return; }
                s.subscribe(new SubscribeConfig.Builder().setServiceName(NAME).build(), new DiscoverySessionCallback() {
                    SubscribeDiscoverySession sess;
                    @Override public void onSubscribeStarted(SubscribeDiscoverySession d) { sess = d; log("subscribe started"); }
                    @Override public void onSessionConfigFailed() { log("subscribe failed"); }
                    @Override public void onServiceDiscovered(PeerHandle p, byte[] ssi, java.util.List<byte[]> mf) {
                        StringBuilder hx = new StringBuilder(); if (ssi != null) for (byte x : ssi) hx.append(String.format("%02x", x));
                        log("DISCOVERED peer=" + p.hashCode() + " ssi=" + hx);
                        if (requested) return; requested = true;
                        WifiAwareNetworkSpecifier.Builder nb = new WifiAwareNetworkSpecifier.Builder(sess, p);
                        if (psk != null) nb.setPskPassphrase(psk);
                        NetworkRequest req = new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
                            .setNetworkSpecifier(nb.build()).build();
                        long t0 = System.currentTimeMillis();
                        log("requesting data path psk=" + (psk != null));
                        cm.requestNetwork(req, new ConnectivityManager.NetworkCallback() {
                            @Override public void onAvailable(Network n) { log("NDP available after " + (System.currentTimeMillis() - t0) + " ms"); }
                            @Override public void onCapabilitiesChanged(Network n, NetworkCapabilities nc) {
                                if (!(nc.getTransportInfo() instanceof WifiAwareNetworkInfo)) return;
                                WifiAwareNetworkInfo i = (WifiAwareNetworkInfo) nc.getTransportInfo();
                                Inet6Address peer = i.getPeerIpv6Addr();
                                log("peer ipv6 ok=" + (peer != null) + " port=" + i.getPort() + " bw=" + nc.getLinkUpstreamBandwidthKbps() + "/" + nc.getLinkDownstreamBandwidthKbps() + " kbps");
                                if (peer != null && !benched) { benched = true; new Thread(() -> bench("aware", n, peer.getHostAddress())).start(); }
                            }
                            @Override public void onUnavailable() { log("NDP UNAVAILABLE after " + (System.currentTimeMillis() - t0) + " ms"); }
                            @Override public void onLost(Network n) { log("NDP lost"); }
                        }, h, 30000);
                    }
                    @Override public void onSessionTerminated() { log("subscribe terminated"); }
                }, h);
            }
            @Override public void onAttachFailed() { log("attach failed"); }
        }, h);
    }
    volatile boolean benched = false;
    static ServerSocket keepServer;

    void startServer() {
        if (keepServer != null) return;
        new Thread(() -> {
            try (ServerSocket ss = new ServerSocket()) {
                keepServer = ss; ss.setReuseAddress(true); ss.bind(new InetSocketAddress("::", PORT + 1));
                log("phone server listening :" + (PORT + 1));
                while (true) {
                    Socket c = ss.accept(); c.setTcpNoDelay(true);
                    log("phone server: conn from " + (c.getInetAddress() instanceof Inet6Address && c.getInetAddress().isLinkLocalAddress() ? "link-local peer" : "other"));
                    new Thread(() -> {
                        try (Socket cc = c) {
                            InputStream in = cc.getInputStream(); OutputStream o = cc.getOutputStream(); int m = in.read();
                            if (m == 'E') { byte[] b = new byte[64]; int r; while ((r = in.read(b)) > 0) { o.write(b, 0, r); o.flush(); } }
                            else if (m == 'D') { byte[] b = new byte[1 << 16]; long tot = 0; int r; long t = System.nanoTime(); while ((r = in.read(b)) > 0) tot += r;
                                o.write(Long.toString(tot).getBytes()); o.flush(); log(String.format("phone server: got %d B in %.2fs", tot, (System.nanoTime() - t) / 1e9)); }
                        } catch (IOException e) { log("phone server conn error " + e.getClass().getSimpleName()); }
                    }).start();
                }
            } catch (IOException e) { log("phone server failed " + e.getClass().getSimpleName() + " " + e.getMessage()); }
        }).start();
    }

    void publish(WifiAwareSession s, String psk) {
        PublishConfig.Builder pb = new PublishConfig.Builder().setServiceName(NAME);
        if (psk != null) pb.setDataPathSecurityConfig(new WifiAwareDataPathSecurityConfig.Builder(Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_SK_128).setPskPassphrase(psk).build());
        s.publish(pb.build(), new DiscoverySessionCallback() {
            @Override public void onPublishStarted(PublishDiscoverySession d) {
                keepDiscovery = d;
                log("publish started");
                WifiAwareNetworkSpecifier.Builder nb = new WifiAwareNetworkSpecifier.Builder(d);
                if (psk != null) nb.setPskPassphrase(psk).setPort(PORT).setTransportProtocol(6);
                NetworkRequest req = new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE).setNetworkSpecifier(nb.build()).build();
                long t0 = System.currentTimeMillis();
                cm.requestNetwork(req, keepCb = new ConnectivityManager.NetworkCallback() {
                    @Override public void onAvailable(Network n) { log("NDP (responder) available after " + (System.currentTimeMillis() - t0) + " ms"); startServer(); }
                    @Override public void onCapabilitiesChanged(Network n, NetworkCapabilities nc) {
                        if (!(nc.getTransportInfo() instanceof WifiAwareNetworkInfo)) return;
                        Inet6Address peer = ((WifiAwareNetworkInfo) nc.getTransportInfo()).getPeerIpv6Addr();
                        log("peer ipv6 ok=" + (peer != null));
                        /* reversed: the Mac is the client */
                    }
                    @Override public void onUnavailable() { log("NDP (responder) UNAVAILABLE"); }
                    @Override public void onLost(Network n) { log("NDP lost"); }
                }, h);
            }
            @Override public void onSessionConfigFailed() { log("publish failed"); }
            @Override public void onMessageReceived(PeerHandle p, byte[] m) { log("message from peer, " + m.length + " B"); }
            @Override public void onSessionTerminated() { log("publish terminated"); }
            @Override public void onServiceLost(PeerHandle p, int r) { log("lost peer reason=" + r); }
        }, h);
    }

    Socket open(Network n, String host) throws IOException {
        IOException last = null;
        for (int k = 0; k < 6; k++) {
            try {
                Socket s = n != null ? n.getSocketFactory().createSocket() : new Socket();
                s.setTcpNoDelay(true);
                s.connect(new InetSocketAddress(InetAddress.getByName(host), PORT), 3000);
                if (k > 0) log("connected on try " + (k + 1));
                return s;
            } catch (IOException e) { last = e; try { Thread.sleep(1000); } catch (InterruptedException ie) {} }
        }
        throw last;
    }

    void bench(String tag, Network n, String host) {
        try {
            long[] rtt = new long[200];
            try (Socket s = open(n, host)) {
                OutputStream o = s.getOutputStream(); InputStream in = s.getInputStream();
                o.write('E'); byte[] f = new byte[64], r = new byte[64];
                for (int k = 0; k < rtt.length; k++) {
                    long t = System.nanoTime(); o.write(f); o.flush();
                    int got = 0; while (got < 64) { int x = in.read(r, got, 64 - got); if (x < 0) throw new EOFException(); got += x; }
                    rtt[k] = System.nanoTime() - t;
                }
            }
            Arrays.sort(rtt);
            log(String.format("%s RTT ms: p50=%.2f p95=%.2f max=%.2f", tag, rtt[100] / 1e6, rtt[190] / 1e6, rtt[199] / 1e6));
            try (Socket s = open(n, host)) {
                OutputStream o = new BufferedOutputStream(s.getOutputStream(), 1 << 16); InputStream in = s.getInputStream();
                o.write('D'); byte[] buf = new byte[1 << 16]; long t = System.nanoTime();
                for (int k = 0; k < MB * 16; k++) o.write(buf);
                o.flush(); s.shutdownOutput();
                String ack = new String(in.readAllBytes());
                double secs = (System.nanoTime() - t) / 1e9;
                log(String.format("%s UPLOAD %d MB in %.2fs = %.1f Mbit/s (mac got %s B)", tag, MB, secs, MB * 8 / secs, ack));
            }
        } catch (Exception e) { log(tag + " bench failed: " + e.getClass().getSimpleName() + " " + e.getMessage()); }
    }
}
