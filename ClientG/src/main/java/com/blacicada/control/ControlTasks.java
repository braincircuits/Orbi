package com.blacicada.control;

import com.blacicada.common.*;
import com.blacicada.config.KernelConfig;
import com.blacicada.proxy.*;
import com.blacicada.config.DirectRoutes;

import java.net.InetSocketAddress;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Supplier;

/**
 * 独立的有界诊断任务，不阻塞控制线程；概览检测复用实际转发路径。
 */
public final class ControlTasks implements AutoCloseable {
    private static final int MAX_CONCURRENT_JOBS = 4;
    private static final int MAX_HISTORY_JOBS = 128;
    private final ExecutorService workers = Executors.newFixedThreadPool(MAX_CONCURRENT_JOBS);
    private final Semaphore slots = new Semaphore(MAX_CONCURRENT_JOBS);
    private final Map<String, Job> jobs = new LinkedHashMap<>();
    private final ControlEvents events;
    private boolean closed;

    private static final class Job {
        Map<String, Object> context = Map.of();
        final String id = UUID.randomUUID().toString();
        final long started = System.nanoTime();
        final String createdAt = Instant.now().toString();
        volatile String state = "queued", stage = "queued";
        volatile Object result = Map.of();
        volatile Future<?> future;
        volatile long elapsed;
        final List<Map<String, Object>> stages = new CopyOnWriteArrayList<>();

        Map<String, Object> view() {
            return Map.of("id", id, "state", state, "stage", stage, "createdAt", createdAt,
                    "elapsedMillis", terminal() ? elapsed : TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started),
                    "stages", List.copyOf(stages), "result", result, "context", context);
        }

        boolean terminal() {
            return Set.of("succeeded", "failed", "cancelled").contains(state);
        }
    }

    @FunctionalInterface
    private interface Work {
        Object run(Job job) throws Exception;
    }

    public ControlTasks(ControlEvents events) {
        this.events = events;
    }

    private Map<String, Object> submit(Work work) {
        return submit(Map.of(), work);
    }

    private synchronized Map<String, Object> submit(Map<String, Object> context, Work work) {
        if (closed || !slots.tryAcquire())
            throw new ControlException(429, "DIAGNOSTICS_BUSY", "同时运行的诊断任务过多，请稍后重试");
        while (jobs.size() >= MAX_HISTORY_JOBS) {
            String oldestCompletedId = jobs.entrySet().stream().filter(e -> e.getValue().terminal()).map(Map.Entry::getKey).findFirst().orElse(null);
            if (oldestCompletedId == null) {
                slots.release();
                throw new ControlException(429, "DIAGNOSTICS_BUSY", "诊断任务已满");
            }
            jobs.remove(oldestCompletedId);
        }
        Job job = new Job();
        job.context = Map.copyOf(context);
        jobs.put(job.id, job);
        job.future = workers.submit(() -> execute(job, work));
        return job.view();
    }

    /**
     * 工作槽只由执行线程在 finally 释放；取消不能提前让仍在清理的任务占用额外线程。
     */
    private void execute(Job job, Work work) {
        try {
            synchronized (job) {
                if (job.state.equals("cancelled")) return;
                job.state = "running";
            }
            events.emit("operation", job.view());
            Object result = work.run(job);
            synchronized (job) {
                if (!job.state.equals("cancelled")) {
                    job.result = result;
                    job.state = "succeeded";
                }
            }
        } catch (Exception e) {
            synchronized (job) {
                if (!job.state.equals("cancelled")) {
                    job.result = failure(job.stage, e);
                    job.state = "failed";
                }
            }
        } finally {
            job.elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - job.started);
            slots.release();
            events.emit("operation", job.view());
        }
    }

    private void stage(Job job, String value) {
        if (value.equals(job.stage)) return;
        job.stage = value;
        job.stages.add(Map.of("stage", value, "elapsedMillis", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - job.started)));
        events.emit("operation", job.view());
    }

    /**
     * 模式、配置或服务生命周期变化时取消与旧出口关联的诊断。
     */
    public synchronized void cancelNetwork() {
        for (Job job : jobs.values()) if (!job.context.isEmpty() && !job.terminal()) cancel(job.id);
    }

    public synchronized void cancelAll() {
        for (Job job : jobs.values()) if (!job.terminal()) cancel(job.id);
    }

    public Map<String, Object> websites(InetSocketAddress proxy, Map<String, Object> context) {
        return submit(context, job -> {
            var items = new ArrayList<Map<String, Object>>();
            for (String id : List.of("github", "google", "youtube")) {
                if (Thread.currentThread().isInterrupted() || job.state.equals("cancelled"))
                    throw new InterruptedException();
                stage(job, id);
                items.add(NetworkProbe.website(proxy, id, NetworkProbe.WEBSITES.get(id)));
                synchronized (job) {
                    if (job.state.equals("cancelled")) throw new InterruptedException();
                    job.result = Map.of("websites", List.copyOf(items));
                }
                events.emit("operation", job.view());
            }
            return job.result;
        });
    }

    public Map<String, Object> exitIp(InetSocketAddress proxy, Map<String, Object> context) {
        return submit(context, job -> {
            stage(job, "exit_ip");
            return NetworkProbe.exitIp(proxy);
        });
    }

    public Map<String, Object> latency(Supplier<io.netty.util.concurrent.Future<Double>> measure,
                                       Map<String, Object> context) {
        return submit(context, job -> {
            stage(job, "latency");
            var future = measure.get();
            try {
                return Map.of("latencyMillis", future.get(5, TimeUnit.SECONDS), "checkedAt", Instant.now().toString());
            } finally {
                if (!future.isDone()) future.cancel(false);
            }
        });
    }

    public Map<String, Object> start(KernelConfig.Profile profile, Authority target) {
        return start(profile, target, OutboundNetwork.DEFAULT);
    }

    public Map<String, Object> start(KernelConfig.Profile profile, Authority target, OutboundNetwork network) {
        return submit(job -> {
            var group = network.newGroup();
            var resolver = network.resolver();
            stage(job, "configuration");
            try (ProxySession session = ProxySessionFactory.create(group.next(), profile.config(), resolver, network)) {
                var opening = session.open(target);
                long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(profile.config().connectTimeoutMillis() * 3L);
                try {
                    while (!opening.isDone()) {
                        if (job.state.equals("cancelled")) throw new InterruptedException();
                        stage(job, session.stage());
                        if (System.nanoTime() > deadline) throw new TimeoutException();
                        opening.await(25);
                    }
                    stage(job, session.stage());
                    if (!opening.isSuccess()) throw new ExecutionException(opening.cause());
                    opening.getNow().close().sync();
                    return Map.of("profileId", profile.id(), "target", target.toString(), "authenticated", true, "tunnelEstablished", true);
                } finally {
                    if (!opening.isDone()) opening.cancel(false);
                }
            } finally {
                resolver.close();
                group.shutdownGracefully(0, 2, TimeUnit.SECONDS).syncUninterruptibly();
            }
        });
    }

    public Map<String, Object> resolve(Authority target, DirectRoutes rules, String defaultId) {
        return resolve(target, rules, defaultId, OutboundNetwork.DEFAULT);
    }

    public Map<String, Object> resolve(Authority target, DirectRoutes rules, String defaultId, OutboundNetwork network) {
        return submit(job -> {
            stage(job, "routing");
            if (!rules.mode().equals("rules")) return routeResult(rules.mode(), defaultId, "global_mode");
            String override = rules.override(target.host());
            if (override != null)
                return routeResult(override, defaultId, "target_rule");
            if (rules.matches(target.host())) return Map.of("action", "direct", "matchedBy", "direct_rule");
            if (rules.needsResolution(target.host())) {
                var group = network.newGroup();
                var resolver = network.resolver();
                try {
                    stage(job, "dns");
                    var result = resolver.getResolver(group.next()).resolveAll(target.unresolved());
                    if (result.await(5000) && result.isSuccess()) {
                        for (InetSocketAddress address : result.getNow())
                            if (rules.matches(address.getAddress()))
                                return Map.of("action", "direct", "matchedBy", "ip_rule", "resolvedAddress", address.getAddress().getHostAddress());
                    }
                    if (!result.isDone()) result.cancel(false);
                } finally {
                    resolver.close();
                    group.shutdownGracefully(0, 2, TimeUnit.SECONDS).syncUninterruptibly();
                }
            }
            return routeResult("proxy", defaultId, "default");
        });
    }

    /**
     * 全局模式、精确规则和默认出口共用同一项检查，缺少默认节点时不能报告可用的代理路由。
     */
    private static Map<String, Object> routeResult(String action, String defaultId, String matchedBy) {
        boolean proxy = action.equals("proxy");
        String effectiveAction = proxy && defaultId.isEmpty() ? "unavailable" : action;
        return Map.of("action", effectiveAction, "profileId", proxy ? defaultId : "", "matchedBy", matchedBy);
    }

    private static Object failure(String stage, Exception failure) {
        Throwable cause = failure;
        while (cause.getCause() != null && cause != cause.getCause()) cause = cause.getCause();
        String text = String.valueOf(cause.getMessage());
        String code = switch (stage) {
            case "dns" -> "DNS_FAILED";
            case "tcp" -> "TCP_CONNECT_FAILED";
            case "tls", "quic_tls" -> "TLS_OR_TRANSPORT_FAILED";
            case "http2_settings" -> "HTTP2_NEGOTIATION_FAILED";
            case "connect" -> "CONNECT_FAILED";
            default -> "DIAGNOSTIC_FAILED";
        };
        if (text.contains("407")) code = "AUTHENTICATION_FAILED";
        else if (cause instanceof java.util.concurrent.TimeoutException || cause instanceof java.net.http.HttpTimeoutException || text.contains("超时") || text.contains("timed out"))
            code = stage.toUpperCase(Locale.ROOT) + "_TIMEOUT";
        return Map.of("code", code, "stage", stage, "message", "诊断未通过，请检查该阶段的网络、证书或代理配置");
    }

    public synchronized Map<String, Object> get(String id) {
        return find(id).view();
    }

    private Job find(String id) {
        Job job = jobs.get(id);
        if (job == null) throw new ControlException(404, "OPERATION_NOT_FOUND", "诊断任务不存在或已过期");
        return job;
    }

    public synchronized void cancel(String id) {
        Job job = find(id);
        synchronized (job) {
            if (job.terminal()) return;
            boolean running = job.state.equals("running");
            job.state = "cancelled";
            job.elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - job.started);
            // 所有任务占用工作槽后立即开始，取消通过中断交给 finally 释放资源。
            if (running && job.future != null) job.future.cancel(true);
        }
        events.emit("operation", job.view());
    }

    @Override
    public synchronized void close() {
        closed = true;
        for (Job job : jobs.values()) if (!job.terminal()) cancel(job.id);
        workers.shutdownNow();
    }
}
