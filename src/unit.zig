const std = @import("std");

///
pub const c = @import("c.zig");
///
pub const hacks = @import("hacks.zig");
///
pub const route = @import("route.zig");

///
pub const Field = hacks.Field;
///
pub const Request = hacks.Request;
///
pub const Context = *c.nxt_unit_ctx_t;
///
pub const RequestInfo = *c.nxt_unit_request_info_t;

///
pub const nxt_error = error {
    unknown
};

/// Wrapper function for any `nxt_unit_*` function.  If the function
///  would return an error code, it returns nxt_error!void instead.
/// Otherwise returns the value.
pub fn nxt_(comptime name: []const u8, args: anytype) NxtRetType(name) {
    const FnName = "nxt_unit_" ++ name;
    const rc = @call(.{}, @field(c, FnName), args);

    // Error code return?
    if (comptime ReturnsErrorCode(FnName)) {
        if (rc != c.NXT_UNIT_OK) {
            std.debug.print("{s} failed\n", .{name});
            return nxt_error.unknown;
        } else return {};
    }
    return rc;
}

/// Only use once; the first Context is "free"; subsequent calls need to
///  use `alloc`
pub fn init(args: anytype) !Context {
    var in = getFromAnonymousOrZeroes(c.nxt_unit_init_t, args);
    var ctx_ptr =  nxt_("init", .{&in});
    if(@ptrCast(?Context, ctx_ptr)) |ctx| return ctx;
    return error.failed_to_initialize;
}

/// If multithreading, each thread needs its own Context; use this
///  function to allocate one based on the main (original) context.
/// `user_data` must be a pointer type.
pub fn alloc(main_ctx: Context, user_data: anytype) !Context {
    var ctx_ptr = nxt_("ctx_alloc", .{ main_ctx, user_data });
    if (@ptrCast(?Context, ctx_ptr)) |ctx| return ctx;
    return error.failed_to_initialize;
}

///
pub fn deinit(ctx: Context) void {
    c.nxt_unit_done(ctx);
}

///
pub fn run(ctx: Context) !void {
    return nxt_("run", .{ctx});
}

/// Writes status and headers to the response; this function should only
///  be called once per request.
pub fn writeHeaders(req: RequestInfo, status: u16, headers: anytype) !void {
    const H = @TypeOf(headers);
    if (@typeInfo(H) == .Struct) {
        try writeHeadersStruct(req, status, headers);
    } else {
        try writeHeadersDynamic(req, status, headers);
    }

    // The response can be sent now--the body can be still be written
    //  with `response_write` and variants
    try nxt_("response_send", .{req});
}

fn writeHeadersStruct(req: RequestInfo, status: u16, headers: anytype) !void {
    const H = @TypeOf(headers);
    // We need to make a first pass to discover how many headers and
    //  how much memory they need
    var n_headers: usize = 0;
    var headers_len: usize = 0;
    inline for (comptime std.meta.fieldNames(H)) |header_name| {
        headers_len += header_name.len;
        headers_len += @field(headers, header_name).len;
        n_headers += 1;
    }

    // We can now initialize a response with these sizes
    try nxt_("response_init", .{req, status,
        @intCast(u32, n_headers), @intCast(u32, headers_len)});

    // Now run through and fill out with the header names and values
    inline for (comptime std.meta.fieldNames(H)) |header_name| {
        const value = @field(headers, header_name);
        try nxt_("response_add_field", .{
           req,
           &header_name[0], @intCast(u8, header_name.len),
           &value[0], @intCast(u32, value.len)
        });
    }
}

fn writeHeadersDynamic(req: RequestInfo, status: u16, headers: anytype) !void {
    // We need to make a first pass to discover how many headers and
    //  how much memory they need
    var n_headers: usize = 0;
    var headers_len: usize = 0;
    for (headers) |header| {
        headers_len += header.name.len + header.value.len;
        n_headers += 1;
    }

    // We can now initialize a response with these sizes
    try nxt_("response_init", .{req, status,
        @intCast(u32, n_headers), @intCast(u32, headers_len)});

    // Now run through and fill out with the header names and values
    for (headers) |header| {
        try nxt_("response_add_field", .{
           req,
           &header.name[0], @intCast(u8, header.name.len),
           &header.value[0], @intCast(u32, header.value.len)
        });
    }
}

//================= IO =================
///
pub const RequestBodyReadError = error {
    readError,
};
///
pub const ResponseWriteError = error {
    writeError
};

///
pub const RequestBodyReader = std.io.Reader(RequestInfo, RequestBodyReadError, readRequestBody);
///
pub const ResponseWriter = std.io.Writer(RequestInfo, ResponseWriteError, writeResponseBytes);

///
pub fn requestBodyReader(req: RequestInfo) RequestBodyReader {
    return RequestBodyReader{ .context=req };
}

fn readRequestBody(req: RequestInfo, bytes: []u8) RequestBodyReadError!usize {
    const read = nxt_("request_read", .{ req, bytes.ptr, bytes.len });
    if (read < 0) return RequestBodyReadError.readError;
    return @intCast(usize, read);
}

///
pub fn responseWriter(req: RequestInfo) ResponseWriter {
    return ResponseWriter{ .context=req };
}

fn writeResponseBytes(req: RequestInfo, bytes: []const u8) ResponseWriteError!usize {
    nxt_("response_write", .{ req, &bytes[0], bytes.len })
       catch return ResponseWriteError.writeError;
    return bytes.len;
}


//================ Request Handlers =================
///
pub const RequestHandler = fn([*c]c.nxt_unit_request_info_t) callconv(.C) void;

/// Wraps a normal Zig function into a RequestHandler.
/// `func` must return `void` or `!void`
pub fn handler(comptime func: anytype) RequestHandler {
    const S = struct {
        pub fn wrapped(req: [*c]c.nxt_unit_request_info_t) callconv(.C) void {
            if (req) |r| {
                if (func(r)) {
                    // Finish the request successfully
                    nxt_("request_done", .{req, c.NXT_UNIT_OK});

                } else |err| {
                    // Copy the error name into a buffer and log it
                    var err_name: [128:0]u8 = std.mem.zeroes([128:0]u8);
                    std.mem.copy(u8, &err_name, @errorName(err));
                    c.nxt_unit_req_log(req, c.NXT_UNIT_LOG_ERR,
                        "Caught error while handling request: %s",
                        &err_name[0]
                    );
                    // Finish the request with an error
                    nxt_("request_done", .{req, c.NXT_UNIT_ERROR});
                }
            } else {
                // Don't think it should be possible to get here
                std.debug.print("request is null\n", .{});
            }
        }
    };
    return S.wrapped;
}

///
pub const Status = struct {
    pub const @"continue":u16 = 100;
    pub const switching_protocols: u16 = 101;
    pub const processing: u16 = 102;
    pub const early_hints: u16 = 103;
    pub const ok: u16 = 200;
    pub const created: u16 = 201;
    pub const accepted: u16 = 202;
    pub const non_authoritative_information: u16 = 203;
    pub const no_content: u16 = 204;
    pub const reset_content: u16 = 205;
    pub const partial_content: u16 = 206;
    pub const multiple_choice: u16 = 300;
    pub const moved_permanently: u16 = 301;
    pub const found: u16 = 302;
    pub const see_other: u16 = 303;
    pub const not_modified: u16 = 304;
    pub const temporary_redirect: u16 = 307;
    pub const permanent_redirect: u16 = 308;
    pub const bad_request: u16 = 400;
    pub const unauthorized: u16 = 401;
    pub const forbidden: u16 = 403;
    pub const not_found: u16 = 404;
    pub const method_not_allowed: u16 = 405;
    pub const not_acceptable: u16 = 406;
    pub const proxy_authentication_required: u16 = 407;
    pub const request_timeout: u16 = 408;
    pub const conflict: u16 = 409;
    pub const gone: u16 = 410;
    pub const length_required: u16 = 411;
    pub const precondition_failed: u16 = 412;
    pub const payload_too_large: u16 = 413;
    pub const uri_too_long: u16 = 414;
    pub const unsupported_media_type: u16 = 415;
    pub const range_not_satisfiable: u16 = 416;
    pub const expectation_failed: u16 = 417;
    pub const im_a_teapot: u16 = 418;
    pub const misdirected_request: u16 = 421;
    pub const upgrade_required: u16 = 426;
    pub const precondition_required: u16 = 428;
    pub const too_many_requests: u16 = 429;
    pub const request_header_fields_too_large: u16 = 431;
    pub const unavailable_for_legal_reasons: u16 = 451;
    pub const internal_server_error: u16 = 500;
    pub const not_implemented: u16 = 501;
    pub const bad_gateway: u16 = 502;
    pub const service_unavailable: u16 = 503;
    pub const gateway_timeout: u16 = 504;
    pub const http_version_not_supported: u16 = 505;
    pub const variant_also_negotiates: u16 = 506;
};

//============== Helpers ==============

// Support functions for wrapper
fn errorReturn() nxt_error!void { return {}; }
const ErrorReturn = @typeInfo(@TypeOf(errorReturn)).Fn.return_type.?;

fn ReturnsErrorCode(comptime FnName: []const u8) bool {
    const TI = @typeInfo(@TypeOf(@field(c, FnName)));
    const RetT = TI.Fn.return_type.?;
    return RetT == c_int;
}

fn NxtRetType(comptime name: []const u8) type {
    const FnName = "nxt_unit_" ++ name;
    const TI = @typeInfo(@TypeOf(@field(c, FnName)));
    const RetT = TI.Fn.return_type.?;

    return if (ReturnsErrorCode(FnName)) ErrorReturn else RetT;
}

// Recursively initializes a value of type T from the struct `args`,
//  initializing unused fields to zeroes.
fn getFromAnonymousOrZeroes(comptime T: type, args: anytype) T {
    var ret = std.mem.zeroes(T);
    inline for (std.meta.fields(@TypeOf(args))) |f| {
        const FT = @TypeOf(@field(ret, f.name));
        if (@typeInfo(FT) == .Struct) {
            @field(ret, f.name) = getFromAnonymousOrZeroes(FT, @field(args, f.name));
        } else {
            @field(ret, f.name) = @field(args, f.name);
        }
    }
    return ret;
}
