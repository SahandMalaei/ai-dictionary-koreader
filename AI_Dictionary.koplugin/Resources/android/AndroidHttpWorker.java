package org.koreader.plugin.aidictionary;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.Reader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Small polling-friendly HTTP worker for KOReader's Lua/JNI bridge.
 *
 * Android must not run long-lived Lua work in a forked copy of the app
 * process: Binder-backed services may become unusable on some firmware.
 * Network I/O therefore runs on a regular Java thread.
 */
public final class AndroidHttpWorker {
    public static final int RUNNING = 0;
    public static final int COMPLETE = 1;
    public static final int FAILED = 2;
    public static final int CANCELLED = 3;

    private static final int MAX_MEMORY_RESPONSE_BYTES = 32 * 1024 * 1024;
    private static final AtomicInteger NEXT_ID = new AtomicInteger(1);
    private static final ConcurrentHashMap<Integer, Request> REQUESTS =
        new ConcurrentHashMap<>();

    private AndroidHttpWorker() {}

    private static final class Request implements Runnable {
        final int id;
        final String url;
        final String method;
        final String authorization;
        final String contentType;
        final String accept;
        final String userAgent;
        final String body;
        final String outputPath;
        final int timeoutMs;
        final StringBuilder response = new StringBuilder();

        volatile int status = RUNNING;
        volatile int responseCode = -1;
        volatile String error = "";
        volatile HttpURLConnection connection;
        volatile Thread thread;

        Request(int id, String url, String method, String authorization,
                String contentType, String accept, String userAgent,
                String body, String outputPath, int timeoutMs) {
            this.id = id;
            this.url = value(url);
            this.method = value(method);
            this.authorization = value(authorization);
            this.contentType = value(contentType);
            this.accept = value(accept);
            this.userAgent = value(userAgent);
            this.body = value(body);
            this.outputPath = value(outputPath);
            this.timeoutMs = Math.max(1000, timeoutMs);
        }

        @Override
        public void run() {
            OutputStream fileOutput = null;
            try {
                HttpURLConnection http = (HttpURLConnection) new URL(url).openConnection();
                connection = http;
                http.setConnectTimeout(timeoutMs);
                http.setReadTimeout(timeoutMs);
                http.setRequestMethod(method.isEmpty() ? "GET" : method);
                http.setInstanceFollowRedirects(true);
                setHeader(http, "Authorization", authorization);
                setHeader(http, "Content-Type", contentType);
                setHeader(http, "Accept", accept);
                setHeader(http, "User-Agent", userAgent);

                if (!body.isEmpty()) {
                    byte[] requestBytes = body.getBytes(StandardCharsets.UTF_8);
                    http.setDoOutput(true);
                    http.setFixedLengthStreamingMode(requestBytes.length);
                    try (OutputStream requestOutput = http.getOutputStream()) {
                        requestOutput.write(requestBytes);
                    }
                }

                responseCode = http.getResponseCode();
                boolean successful = responseCode >= 200 && responseCode < 300;
                InputStream input = successful ? http.getInputStream() : http.getErrorStream();
                if (successful && !outputPath.isEmpty()) {
                    File outputFile = new File(outputPath);
                    File parent = outputFile.getParentFile();
                    if (parent != null && !parent.exists() && !parent.mkdirs()) {
                        throw new IllegalStateException("Could not create output directory");
                    }
                    fileOutput = new FileOutputStream(outputFile);
                }

                if (input != null && fileOutput != null) {
                    byte[] buffer = new byte[8192];
                    int total = 0;
                    int count;
                    while (status == RUNNING && (count = input.read(buffer)) != -1) {
                        total += count;
                        if (total > MAX_MEMORY_RESPONSE_BYTES) {
                            throw new IllegalStateException("HTTP response is too large");
                        }
                        fileOutput.write(buffer, 0, count);
                    }
                    input.close();
                } else if (input != null) {
                    Reader reader = new InputStreamReader(input, StandardCharsets.UTF_8);
                    char[] buffer = new char[4096];
                    int total = 0;
                    int count;
                    while (status == RUNNING && (count = reader.read(buffer)) != -1) {
                        total += count;
                        if (total > MAX_MEMORY_RESPONSE_BYTES) {
                            throw new IllegalStateException("HTTP response is too large");
                        }
                        synchronized (response) {
                            response.append(buffer, 0, count);
                        }
                    }
                    reader.close();
                }
                if (fileOutput != null) {
                    fileOutput.flush();
                    fileOutput.close();
                    fileOutput = null;
                }

                if (status == RUNNING) {
                    status = successful ? COMPLETE : FAILED;
                    if (!successful) {
                        error = "HTTP " + responseCode + ": " + getText(id);
                    }
                }
            } catch (Exception exception) {
                if (status == RUNNING) {
                    error = exception.toString();
                    status = FAILED;
                }
            } finally {
                if (fileOutput != null) {
                    try { fileOutput.close(); } catch (Exception ignored) {}
                }
                HttpURLConnection http = connection;
                connection = null;
                if (http != null) http.disconnect();
                if (status != COMPLETE && !outputPath.isEmpty()) {
                    try { new File(outputPath).delete(); } catch (Exception ignored) {}
                }
            }
        }
    }

    public static int start(String url, String method, String authorization,
                            String contentType, String accept, String userAgent,
                            String body, String outputPath, int timeoutMs) {
        int id = NEXT_ID.getAndIncrement();
        Request request = new Request(id, url, method, authorization, contentType,
            accept, userAgent, body, outputPath, timeoutMs);
        REQUESTS.put(id, request);
        Thread thread = new Thread(request, "AI-Dictionary-HTTP-" + id);
        thread.setDaemon(true);
        request.thread = thread;
        thread.start();
        return id;
    }

    public static int getStatus(int id) {
        Request request = REQUESTS.get(id);
        return request == null ? FAILED : request.status;
    }

    public static int getResponseCode(int id) {
        Request request = REQUESTS.get(id);
        return request == null ? -1 : request.responseCode;
    }

    public static String getText(int id) {
        Request request = REQUESTS.get(id);
        if (request == null) return "";
        synchronized (request.response) {
            return request.response.toString();
        }
    }

    public static String getError(int id) {
        Request request = REQUESTS.get(id);
        return request == null ? "Unknown HTTP request" : request.error;
    }

    public static void cancel(int id) {
        Request request = REQUESTS.get(id);
        if (request == null || request.status != RUNNING) return;
        request.status = CANCELLED;
        HttpURLConnection http = request.connection;
        if (http != null) http.disconnect();
        Thread thread = request.thread;
        if (thread != null) thread.interrupt();
        if (!request.outputPath.isEmpty()) {
            try { new File(request.outputPath).delete(); } catch (Exception ignored) {}
        }
    }

    public static void cleanup(int id) {
        REQUESTS.remove(id);
    }

    private static String value(String value) {
        return value == null ? "" : value;
    }

    private static void setHeader(HttpURLConnection http, String name, String value) {
        if (value != null && !value.isEmpty()) http.setRequestProperty(name, value);
    }
}
