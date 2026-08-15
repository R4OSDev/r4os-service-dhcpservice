const r4os = @import("r4os");

const service_name = "DHCPSVC";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const dhcp_service_timeout_ms: u64 = 1000;

const LeaseTiming = struct {
    elapsed_seconds: u32 = 0,
    remaining_seconds: u32 = 0,
    renew_in_seconds: u32 = 0,
    rebind_in_seconds: u32 = 0,
};

const DhcpServiceState = struct {
    requests: u64 = 0,
    status_requests: u64 = 0,
    action_requests: u64 = 0,
    bad_ops: u64 = 0,
    self_tests: u64 = 0,
    operation_pending: bool = false,
    pending_label: [16]u8 = .{0} ** 16,
    last_result: i32 = r4os.abi.net_tx_backend_error,
    last_status_valid: bool = false,
    last_status: r4os.abi.DhcpStatus = .{},
    lease_start_tick: u64 = 0,
    tracked_xid: u32 = 0,
    tracked_ip: [4]u8 = .{0} ** 4,
    last_error: [32]u8 = .{0} ** 32,
};

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(app.sys.argsRaw(), selftest_arg)) return runSelfTest(&app);
    if (hasArg(app.sys.argsRaw(), ping_arg)) return runPing(&app);
    return runService(&app);
}

fn runService(app: *const App) i32 {
    if (!app.sys.hasFn("service_call")) return r4os.abi.service_api_result_invalid;

    var info: r4os.abi.ServiceInfo = .{};
    var handle: u32 = 0;
    var waited: u32 = 0;
    while (waited < 100 and handle == 0) : (waited += 1) {
        const rc = app.sys.serviceEndpointRegister(service_name, 0, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            handle = info.handle;
            app.sys.write("DHCPSVC endpoint handle=");
            app.sys.printU64(@intCast(handle));
            app.sys.println("");
            break;
        }
        app.sys.sleepTicks(1);
    }
    if (handle == 0) {
        app.sys.println("DHCPSVC endpoint registration failed");
        return r4os.abi.service_api_result_no_endpoint;
    }

    var state = DhcpServiceState{};
    copyFixed(state.pending_label[0..], "idle");
    copyFixed(state.last_error[0..], "ready");
    _ = refreshStatus(app, &state);

    while (!app.sys.programShouldClose()) {
        const poll = app.sys.serviceEndpointPoll(handle);
        if (poll < 0) {
            _ = app.sys.serviceEndpointUnregister(handle);
            return poll;
        }
        if (poll > 0) {
            const rc = handleRequest(app, handle, &state);
            if (rc < 0) {
                _ = app.sys.serviceEndpointUnregister(handle);
                return rc;
            }
        }
        app.sys.sleepTicks(1);
    }

    _ = app.sys.serviceEndpointUnregister(handle);
    app.sys.println("DHCPSVC stopped cleanly");
    return 0;
}

fn handleRequest(app: *const App, handle: u32, state: *DhcpServiceState) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var payload: [r4os.abi.service_api_max_payload]u8 = undefined;
    const got = app.sys.serviceEndpointRecv(handle, &header, payload[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;

    state.requests +%= 1;
    return switch (header.op) {
        r4os.abi.net_service_op_status => replyTextStatus(app, handle, header.request_id, state),
        r4os.abi.net_service_op_dhcp_status_result => replyStatusResult(app, handle, header.request_id, state),
        r4os.abi.net_service_op_dhcp_acquire, r4os.abi.net_service_op_dhcp_renew, r4os.abi.net_service_op_dhcp_release => replyActionText(app, handle, header.request_id, header.op, state),
        r4os.abi.net_service_op_dhcp_acquire_result, r4os.abi.net_service_op_dhcp_renew_result, r4os.abi.net_service_op_dhcp_release_result => replyActionResult(app, handle, header.request_id, header.op, state),
        else => {
            state.bad_ops +%= 1;
            return app.sys.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
        },
    };
}

fn replyTextStatus(app: *const App, handle: u32, request_id: u32, state: *DhcpServiceState) i32 {
    state.status_requests +%= 1;
    _ = refreshStatus(app, state);
    var buf: [512]u8 = .{0} ** 512;
    var w = Writer{ .out = buf[0..] };
    writeStatusText(&w, app, state);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, w.slice());
}

fn replyStatusResult(app: *const App, handle: u32, request_id: u32, state: *DhcpServiceState) i32 {
    state.status_requests +%= 1;
    _ = refreshStatus(app, state);
    const status = makeStatusResult(app, state);
    const bytes: [*]const u8 = @ptrCast(&status);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.NetServiceDhcpStatus)]);
}

fn replyActionText(app: *const App, handle: u32, request_id: u32, op: u16, state: *DhcpServiceState) i32 {
    const result = performAction(app, state, op);
    var buf: [512]u8 = .{0} ** 512;
    var w = Writer{ .out = buf[0..] };
    writeActionText(&w, app, state, result);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, w.slice());
}

fn replyActionResult(app: *const App, handle: u32, request_id: u32, op: u16, state: *DhcpServiceState) i32 {
    const result = performAction(app, state, op);
    const bytes: [*]const u8 = @ptrCast(&result);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.NetServiceDhcpResult)]);
}

fn performAction(app: *const App, state: *DhcpServiceState, op: u16) r4os.abi.NetServiceDhcpResult {
    const action = actionForOp(op);
    state.action_requests +%= 1;
    state.operation_pending = true;
    copyFixed(state.pending_label[0..], actionName(action));

    const tx = switch (action) {
        r4os.abi.net_service_dhcp_action_acquire => app.net.netDhcpAcquire(),
        r4os.abi.net_service_dhcp_action_renew => app.net.netDhcpRenew(),
        r4os.abi.net_service_dhcp_action_release => app.net.netDhcpRelease(),
        else => r4os.abi.net_tx_backend_error,
    };

    state.operation_pending = false;
    copyFixed(state.pending_label[0..], "idle");
    state.last_result = normalizeNetTxCode(tx);
    if (!refreshStatus(app, state)) copyFixed(state.last_error[0..], app.net.netTxResultName(state.last_result));

    if (state.last_status_valid) {
        const bound = (state.last_status.flags & r4os.abi.dhcp_status_flag_bound) != 0;
        if ((action == r4os.abi.net_service_dhcp_action_acquire or action == r4os.abi.net_service_dhcp_action_renew) and state.last_result == r4os.abi.net_tx_ok and bound) {
            markLeaseTracked(app, state, &state.last_status, true);
        } else if (action == r4os.abi.net_service_dhcp_action_release and !bound) {
            clearLeaseTracked(state);
        }
    }

    return makeActionResult(app, state, action, state.last_result);
}

fn refreshStatus(app: *const App, state: *DhcpServiceState) bool {
    var raw: r4os.abi.DhcpStatus = .{};
    const rc = app.net.netDhcpStatus(&raw);
    if (rc <= 0) {
        state.last_status_valid = false;
        copyFixed(state.last_error[0..], "status-unavailable");
        return false;
    }
    state.last_status = raw;
    state.last_status_valid = true;
    if (spanZ(raw.last_error[0..]).len != 0) copyFixed(state.last_error[0..], spanZ(raw.last_error[0..]));
    markLeaseTracked(app, state, &raw, false);
    return true;
}

fn markLeaseTracked(app: *const App, state: *DhcpServiceState, raw: *const r4os.abi.DhcpStatus, force_start: bool) void {
    const bound = (raw.flags & r4os.abi.dhcp_status_flag_bound) != 0;
    if (!bound) {
        clearLeaseTracked(state);
        return;
    }
    const changed = state.tracked_xid != raw.xid or !sameIp(state.tracked_ip, raw.offered_ip);
    if (force_start or state.lease_start_tick == 0 or changed) state.lease_start_tick = app.sys.ticks();
    state.tracked_xid = raw.xid;
    state.tracked_ip = raw.offered_ip;
}

fn clearLeaseTracked(state: *DhcpServiceState) void {
    state.lease_start_tick = 0;
    state.tracked_xid = 0;
    state.tracked_ip = .{0} ** 4;
}

fn makeStatusResult(app: *const App, state: *const DhcpServiceState) r4os.abi.NetServiceDhcpStatus {
    const raw = state.last_status;
    const timing = leaseTiming(app, state, raw);
    var out = r4os.abi.NetServiceDhcpStatus{
        .runtime_state = raw.runtime_state,
        .flags = serviceDhcpFlags(state, raw),
        .xid = raw.xid,
        .offered_ip = raw.offered_ip,
        .server_ip = raw.server_ip,
        .netmask = raw.netmask,
        .gateway_ip = raw.gateway_ip,
        .dns_ip = raw.dns_ip,
        .lease_seconds = raw.lease_seconds,
        .renew_seconds = raw.renew_seconds,
        .rebind_seconds = raw.rebind_seconds,
        .elapsed_seconds = timing.elapsed_seconds,
        .remaining_seconds = timing.remaining_seconds,
        .renew_in_seconds = timing.renew_in_seconds,
        .rebind_in_seconds = timing.rebind_in_seconds,
        .last_attempt = raw.last_attempt,
        .last_type = raw.last_type,
        .discover_tx = raw.discover_tx,
        .offer_rx = raw.offer_rx,
        .request_tx = raw.request_tx,
        .ack_rx = raw.ack_rx,
        .nak_rx = raw.nak_rx,
        .release_tx = raw.release_tx,
        .retries = raw.retries,
        .timeouts = raw.timeouts,
        .release_errors = raw.release_errors,
        .malformed = raw.malformed,
        .self_tests = raw.self_tests + state.self_tests,
    };
    copyFixed(out.pending_label[0..], spanZ(state.pending_label[0..]));
    copyFixed(out.last_error[0..], if (state.last_status_valid) spanZ(raw.last_error[0..]) else spanZ(state.last_error[0..]));
    return out;
}

fn makeActionResult(app: *const App, state: *const DhcpServiceState, action: u16, result: i32) r4os.abi.NetServiceDhcpResult {
    const raw = state.last_status;
    const timing = leaseTiming(app, state, raw);
    var flags = serviceDhcpFlags(state, raw);
    flags = withServiceStatus(flags, serviceStatusFromTxResult(result, spanZ(state.last_error[0..])));
    return .{
        .action = action,
        .result = normalizeNetTxCode(result),
        .flags = flags,
        .offered_ip = raw.offered_ip,
        .server_ip = raw.server_ip,
        .netmask = raw.netmask,
        .gateway_ip = raw.gateway_ip,
        .dns_ip = raw.dns_ip,
        .lease_seconds = raw.lease_seconds,
        .elapsed_seconds = timing.elapsed_seconds,
        .remaining_seconds = timing.remaining_seconds,
        .renew_in_seconds = timing.renew_in_seconds,
        .rebind_in_seconds = timing.rebind_in_seconds,
        .last_attempt = raw.last_attempt,
        .last_type = raw.last_type,
        .discover_tx = raw.discover_tx,
        .offer_rx = raw.offer_rx,
        .request_tx = raw.request_tx,
        .ack_rx = raw.ack_rx,
        .nak_rx = raw.nak_rx,
        .release_tx = raw.release_tx,
        .retries = raw.retries,
        .timeouts = raw.timeouts,
        .release_errors = raw.release_errors,
        .malformed = raw.malformed,
    };
}

fn leaseTiming(app: *const App, state: *const DhcpServiceState, raw: r4os.abi.DhcpStatus) LeaseTiming {
    if ((raw.flags & r4os.abi.dhcp_status_flag_bound) == 0 or state.lease_start_tick == 0) return .{};
    const hz = app.sys.monotonicHz();
    if (hz == 0) return .{};
    const now = app.sys.ticks();
    const elapsed_ticks = if (now > state.lease_start_tick) now - state.lease_start_tick else 0;
    const elapsed_u64 = elapsed_ticks / hz;
    const elapsed: u32 = if (elapsed_u64 > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(elapsed_u64);
    return .{
        .elapsed_seconds = elapsed,
        .remaining_seconds = secondsRemaining(raw.lease_seconds, elapsed),
        .renew_in_seconds = secondsRemaining(raw.renew_seconds, elapsed),
        .rebind_in_seconds = secondsRemaining(raw.rebind_seconds, elapsed),
    };
}

fn serviceDhcpFlags(state: *const DhcpServiceState, raw: r4os.abi.DhcpStatus) u32 {
    var flags: u32 = 0;
    if ((raw.flags & r4os.abi.dhcp_status_flag_bound) != 0) flags |= r4os.abi.net_service_dhcp_flag_bound;
    if ((raw.flags & r4os.abi.dhcp_status_flag_dns_configured) != 0) flags |= r4os.abi.net_service_dhcp_flag_dns_configured;
    if (state.operation_pending or (raw.flags & r4os.abi.dhcp_status_flag_pending) != 0) flags |= r4os.abi.net_service_dhcp_flag_pending;
    if ((raw.flags & r4os.abi.dhcp_status_flag_desired) != 0) flags |= r4os.abi.net_service_dhcp_flag_desired;
    if ((raw.flags & r4os.abi.dhcp_status_flag_task_started) != 0) flags |= r4os.abi.net_service_dhcp_flag_task_started;
    if ((raw.flags & r4os.abi.dhcp_status_flag_link_up) != 0) flags |= r4os.abi.net_service_dhcp_flag_link_up;
    if ((raw.flags & r4os.abi.dhcp_status_flag_retry_wait) != 0) flags |= r4os.abi.net_service_dhcp_flag_retry_wait;
    return flags;
}

fn actionForOp(op: u16) u16 {
    return switch (op) {
        r4os.abi.net_service_op_dhcp_acquire, r4os.abi.net_service_op_dhcp_acquire_result => r4os.abi.net_service_dhcp_action_acquire,
        r4os.abi.net_service_op_dhcp_renew, r4os.abi.net_service_op_dhcp_renew_result => r4os.abi.net_service_dhcp_action_renew,
        r4os.abi.net_service_op_dhcp_release, r4os.abi.net_service_op_dhcp_release_result => r4os.abi.net_service_dhcp_action_release,
        else => 0,
    };
}

fn actionName(action: u16) []const u8 {
    return switch (action) {
        r4os.abi.net_service_dhcp_action_acquire => "acquire",
        r4os.abi.net_service_dhcp_action_renew => "renew",
        r4os.abi.net_service_dhcp_action_release => "release",
        else => "unknown",
    };
}

fn writeStatusText(w: *Writer, app: *const App, state: *const DhcpServiceState) void {
    const raw = state.last_status;
    const timing = leaseTiming(app, state, raw);
    w.text("state=");
    w.text(if ((raw.flags & r4os.abi.dhcp_status_flag_bound) != 0) "bound" else "released");
    w.text(" pending=");
    w.text(if ((serviceDhcpFlags(state, raw) & r4os.abi.net_service_dhcp_flag_pending) != 0) "yes" else "no");
    w.text(" op=");
    w.text(spanZ(state.pending_label[0..]));
    w.text(" ip=");
    w.ip(raw.offered_ip);
    w.text(" server=");
    w.ip(raw.server_ip);
    w.text(" lease=");
    w.num(raw.lease_seconds);
    w.text(" elapsed=");
    w.num(timing.elapsed_seconds);
    w.text(" remaining=");
    w.num(timing.remaining_seconds);
    w.text(" renew_in=");
    w.num(timing.renew_in_seconds);
    w.text(" rebind_in=");
    w.num(timing.rebind_in_seconds);
    w.text(" discover=");
    w.num(raw.discover_tx);
    w.text(" offer=");
    w.num(raw.offer_rx);
    w.text(" request=");
    w.num(raw.request_tx);
    w.text(" ack=");
    w.num(raw.ack_rx);
    w.text(" nak=");
    w.num(raw.nak_rx);
    w.text(" release=");
    w.num(raw.release_tx);
    w.text(" retry=");
    w.num(raw.retries);
    w.text(" timeout=");
    w.num(raw.timeouts);
    w.text(" relerr=");
    w.num(raw.release_errors);
    w.text(" malformed=");
    w.num(raw.malformed);
    w.text(" attempt=");
    w.num(raw.last_attempt);
    w.text(" last=");
    w.text(if (state.last_status_valid) spanZ(raw.last_error[0..]) else spanZ(state.last_error[0..]));
}

fn writeActionText(w: *Writer, app: *const App, state: *const DhcpServiceState, result: r4os.abi.NetServiceDhcpResult) void {
    w.text("action=");
    w.text(actionName(result.action));
    w.text(" result=");
    w.text(app.net.netTxResultName(result.result));
    w.text(" code=");
    w.signed(result.result);
    w.text(" state=");
    w.text(if ((result.flags & r4os.abi.net_service_dhcp_flag_bound) != 0) "bound" else "released");
    w.text(" pending=");
    w.text(if ((result.flags & r4os.abi.net_service_dhcp_flag_pending) != 0) "yes" else "no");
    w.text(" ip=");
    w.ip(result.offered_ip);
    w.text(" server=");
    w.ip(result.server_ip);
    w.text(" remaining=");
    w.num(result.remaining_seconds);
    w.text(" renew_in=");
    w.num(result.renew_in_seconds);
    w.text(" rebind_in=");
    w.num(result.rebind_in_seconds);
    w.text(" timeout=");
    w.num(result.timeouts);
    w.text(" retry=");
    w.num(result.retries);
    w.text(" relerr=");
    w.num(result.release_errors);
    w.text(" status=");
    w.text(serviceStatusName(result.flags));
    w.text(" last=");
    w.text(spanZ(state.last_error[0..]));
}

fn runPing(app: *const App) i32 {
    app.sys.println("DHCPSVC ping");
    var handle: u32 = 0;
    if (!ensureRunningAndOpen(app, &handle)) {
        app.sys.println("DHCPSVC ping failed");
        return 1;
    }
    defer _ = app.sys.serviceClose(handle);

    var header: r4os.abi.ServiceMessageHeader = .{};
    var response: [@sizeOf(r4os.abi.NetServiceDhcpStatus)]u8 = undefined;
    const got = app.sys.serviceCall(handle, r4os.abi.net_service_op_dhcp_status_result, "", &header, response[0..], app.sys.ticksFromMilliseconds(dhcp_service_timeout_ms));
    if (got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceDhcpStatus))) or header.status != r4os.abi.service_api_result_ok) {
        app.sys.println("DHCPSVC ping failed");
        return 1;
    }
    var status = r4os.abi.NetServiceDhcpStatus{};
    copyStruct(&status, response[0..]);
    if (status.magic != r4os.abi.net_service_dhcp_status_magic or status.version != r4os.abi.net_service_dhcp_status_version) {
        app.sys.println("DHCPSVC ping failed");
        return 1;
    }
    app.sys.println("DHCPSVC ping: OK");
    return 0;
}

fn runSelfTest(app: *const App) i32 {
    app.sys.println("DHCPSVC selftest");
    if (!app.sys.hasFn("service_start")) return fail(app, "manager-api");
    if (!app.sys.hasFn("service_call")) return fail(app, "service-api");
    if (!localContractSelfTest(app)) return fail(app, "local-contract");

    var handle: u32 = 0;
    if (!ensureRunningAndOpen(app, &handle)) return fail(app, "open");
    defer _ = app.sys.serviceClose(handle);

    var header: r4os.abi.ServiceMessageHeader = .{};
    var status_response: [@sizeOf(r4os.abi.NetServiceDhcpStatus)]u8 = undefined;
    const status_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_dhcp_status_result, "", &header, status_response[0..], app.sys.ticksFromMilliseconds(dhcp_service_timeout_ms));
    if (status_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceDhcpStatus))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "status");
    var status = r4os.abi.NetServiceDhcpStatus{};
    copyStruct(&status, status_response[0..]);
    if (status.magic != r4os.abi.net_service_dhcp_status_magic or status.version != r4os.abi.net_service_dhcp_status_version) return fail(app, "status-magic");

    var text_response: [256]u8 = .{0} ** 256;
    const text_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_status, "", &header, text_response[0..], app.sys.ticksFromMilliseconds(dhcp_service_timeout_ms));
    if (text_got <= 0 or header.status != r4os.abi.service_api_result_ok) return fail(app, "text-status");
    if (!contains(text_response[0..@intCast(text_got)], "state=")) return fail(app, "text-state");

    var response_header: r4os.abi.ServiceMessageHeader = .{};
    var small: [8]u8 = .{0} ** 8;
    const bad_op = app.sys.serviceCall(handle, 0xFFFF, "", &response_header, small[0..], app.sys.ticksFromMilliseconds(100));
    if (bad_op < 0 or response_header.status != r4os.abi.service_api_result_bad_op) return fail(app, "bad-op");

    app.sys.println("DHCPSVC selftest: OK");
    return 0;
}

fn localContractSelfTest(app: *const App) bool {
    var state = DhcpServiceState{};
    copyFixed(state.pending_label[0..], "idle");
    copyFixed(state.last_error[0..], "selftest");
    state.self_tests = 1;
    state.last_status_valid = true;
    state.last_status = .{
        .discover_tx = 1,
        .offer_rx = 1,
        .request_tx = 1,
        .ack_rx = 1,
        .xid = 0x1234ABCD,
        .offered_ip = .{ 10, 0, 2, 15 },
        .server_ip = .{ 10, 0, 2, 2 },
        .netmask = .{ 255, 255, 255, 0 },
        .gateway_ip = .{ 10, 0, 2, 2 },
        .dns_ip = .{ 10, 0, 2, 3 },
        .lease_seconds = 120,
        .renew_seconds = 60,
        .rebind_seconds = 105,
        .flags = r4os.abi.dhcp_status_flag_bound | r4os.abi.dhcp_status_flag_dns_configured |
            r4os.abi.dhcp_status_flag_desired | r4os.abi.dhcp_status_flag_task_started |
            r4os.abi.dhcp_status_flag_link_up,
        .last_attempt = 2,
        .last_type = 5,
        .runtime_state = 6,
    };
    copyFixed(state.last_status.last_error[0..], "bound");
    state.lease_start_tick = app.sys.ticks();
    state.tracked_xid = state.last_status.xid;
    state.tracked_ip = state.last_status.offered_ip;

    const status = makeStatusResult(app, &state);
    if (status.magic != r4os.abi.net_service_dhcp_status_magic or status.version != r4os.abi.net_service_dhcp_status_version) return false;
    if ((status.flags & r4os.abi.net_service_dhcp_flag_bound) == 0 or (status.flags & r4os.abi.net_service_dhcp_flag_dns_configured) == 0) return false;
    if ((status.flags & r4os.abi.net_service_dhcp_flag_desired) == 0 or (status.flags & r4os.abi.net_service_dhcp_flag_task_started) == 0 or (status.flags & r4os.abi.net_service_dhcp_flag_link_up) == 0) return false;
    if (status.runtime_state != 6) return false;
    if (status.lease_seconds != 120 or status.remaining_seconds != 120 or status.renew_in_seconds != 60) return false;
    if (!sameIp(status.offered_ip, .{ 10, 0, 2, 15 }) or !sameIp(status.dns_ip, .{ 10, 0, 2, 3 })) return false;

    const ok = makeActionResult(app, &state, r4os.abi.net_service_dhcp_action_acquire, r4os.abi.net_tx_ok);
    if (ok.magic != r4os.abi.net_service_dhcp_result_magic or ok.result != r4os.abi.net_tx_ok) return false;
    if (!textEquals(serviceStatusName(ok.flags), "ok")) return false;
    const busy = makeActionResult(app, &state, r4os.abi.net_service_dhcp_action_renew, r4os.abi.net_tx_busy);
    if (!textEquals(serviceStatusName(busy.flags), "would-block")) return false;

    var buf: [256]u8 = .{0} ** 256;
    var w = Writer{ .out = buf[0..] };
    writeStatusText(&w, app, &state);
    if (!contains(w.slice(), "state=bound") or !contains(w.slice(), "lease=120")) return false;
    return true;
}

fn ensureRunningAndOpen(app: *const App, out_handle: *u32) bool {
    var info: r4os.abi.ServiceInfo = .{};
    const status = app.sys.serviceStatus(service_name, &info);
    if (status != r4os.abi.service_api_result_ok) return false;
    if (info.state != r4os.abi.service_state_running) {
        const start = app.sys.serviceStart(service_name, &info);
        if (start != r4os.abi.service_api_result_ok) return false;
    }
    var tick: u32 = 0;
    while (tick < 160) : (tick += 1) {
        const open_rc = app.sys.serviceOpen(service_name, &info);
        if (open_rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            out_handle.* = info.handle;
            return true;
        }
        app.sys.sleepTicks(1);
    }
    return false;
}

fn withServiceStatus(flags: u32, status: u32) u32 {
    return (flags & ~r4os.abi.net_service_status_mask) | (status << r4os.abi.net_service_status_shift);
}

fn serviceStatusFromTxResult(result: i32, last_error: []const u8) u32 {
    return switch (normalizeNetTxCode(result)) {
        r4os.abi.net_tx_ok => r4os.abi.net_service_status_ok,
        r4os.abi.net_tx_busy => r4os.abi.net_service_status_would_block,
        r4os.abi.net_tx_backend_error => if (contains(last_error, "timeout")) r4os.abi.net_service_status_timeout else r4os.abi.net_service_status_failed,
        else => r4os.abi.net_service_status_failed,
    };
}

fn serviceStatusName(flags: u32) []const u8 {
    return switch ((flags & r4os.abi.net_service_status_mask) >> r4os.abi.net_service_status_shift) {
        r4os.abi.net_service_status_idle => "idle",
        r4os.abi.net_service_status_pending => "pending",
        r4os.abi.net_service_status_ok => "ok",
        r4os.abi.net_service_status_timeout => "timeout",
        r4os.abi.net_service_status_failed => "failed",
        r4os.abi.net_service_status_cancelled => "cancelled",
        r4os.abi.net_service_status_would_block => "would-block",
        else => "failed",
    };
}

fn normalizeNetTxCode(code: i32) i32 {
    return switch (code) {
        r4os.abi.net_tx_ok,
        r4os.abi.net_tx_no_adapter,
        r4os.abi.net_tx_link_down,
        r4os.abi.net_tx_busy,
        r4os.abi.net_tx_too_large,
        r4os.abi.net_tx_unsupported,
        r4os.abi.net_tx_backend_error,
        => code,
        else => r4os.abi.net_tx_backend_error,
    };
}

fn secondsRemaining(total: u32, elapsed: u32) u32 {
    if (total == 0 or elapsed >= total) return 0;
    return total - elapsed;
}

fn fail(app: *const App, label: []const u8) i32 {
    app.sys.write("DHCPSVC selftest FAILED: ");
    app.sys.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (textEqualsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn textEqualsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn sameIp(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn copyFixed(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const len = @min(value.len, out.len - 1);
    if (len != 0) copyBytes(out[0..len], value[0..len]);
}

fn copyBytes(out: []u8, value: []const u8) void {
    var i: usize = 0;
    while (i < out.len and i < value.len) : (i += 1) out[i] = value[i];
}

fn copyStruct(out: anytype, data: []const u8) void {
    const out_bytes: [*]u8 = @ptrCast(out);
    const size = @sizeOf(@TypeOf(out.*));
    const len = @min(size, data.len);
    var i: usize = 0;
    while (i < len) : (i += 1) out_bytes[i] = data[i];
}

fn spanZ(value: []const u8) []const u8 {
    return value[0..stringLenZ(value)];
}

fn stringLenZ(value: []const u8) usize {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return len;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (haystack[start + i] != needle[i]) break;
        }
        if (i == needle.len) return true;
    }
    return false;
}

fn textEquals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

const Writer = struct {
    out: []u8,
    pos: usize = 0,

    fn put(self: *Writer, ch: u8) void {
        if (self.pos >= self.out.len) return;
        self.out[self.pos] = ch;
        self.pos += 1;
    }

    fn text(self: *Writer, value: []const u8) void {
        for (value) |ch| if (ch != 0) self.put(ch);
    }

    fn slice(self: *const Writer) []const u8 {
        return self.out[0..self.pos];
    }

    fn num(self: *Writer, value: anytype) void {
        var buf: [20]u8 = undefined;
        var pos: usize = buf.len;
        var n: u64 = @intCast(value);
        if (n == 0) {
            self.put('0');
            return;
        }
        while (n > 0) {
            pos -= 1;
            buf[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        self.text(buf[pos..]);
    }

    fn signed(self: *Writer, value: i32) void {
        if (value < 0) {
            self.put('-');
            self.num(@as(u32, @intCast(-value)));
        } else {
            self.num(@as(u32, @intCast(value)));
        }
    }

    fn ip(self: *Writer, value: [4]u8) void {
        self.num(value[0]);
        self.put('.');
        self.num(value[1]);
        self.put('.');
        self.num(value[2]);
        self.put('.');
        self.num(value[3]);
    }
};
