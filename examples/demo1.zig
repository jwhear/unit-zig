const std = @import("std");
const unit = @import("unit");

const max_request_body_size = 1024 * 1024 * 10;

// Our routing table
const m = unit.route;
const routes = .{
    .{ .methods=m.POST|m.PUT, .path="/write", .handler=postStuff  },
    .{ .methods=m.ANY,        .path="/error", .handler=throwError },
    .{ .methods=m.GET,        .path="/items/:item_id", .handler=getItem },
    .{ .methods=m.ANY,        .path="**",     .handler=missingPage  },
};

// This function will be invoked with every client request
fn onRequest(req: unit.RequestInfo) !void {
    std.debug.print("Handling request\n", .{});

    // You can write whatever custom logic you want--in this case
    // I'll just use the route functionality to direct the request
    //  to a handler
    try unit.route.route(req, routes);
}

pub fn main() anyerror!void {

    // Initialize, creating a context.  If multithreading, each thread
    //  should create its own context.
    var ctx = try unit.init(.{
        .callbacks = .{
            .request_handler = comptime unit.handler(onRequest),
        },
    });
    defer unit.deinit(ctx);

    // This runs a loop until the Unit Daemon tells the application to
    //  shut down.  If you want more power you can use
    //     unit.nxt_("run_once", .{ctx});
    // and provide your own event loop
    try unit.run(ctx);
}

fn postStuff(req: unit.RequestInfo) !void {
    // This handler demonstrates how to read the request body, write
    //  headers and a response body.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var bodyReader = unit.requestBodyReader(req);
    var writer = unit.responseWriter(req);
    var request = unit.Request.cast(req.request);

    // Start an "OK" response with all the headers we want to send
    try unit.writeHeaders(req, unit.Status.ok, .{
        .@"Content-Type"="text/plain",
    });

    // Now we can write the body of the response
    try writer.print("target = {s}\n", .{ request.target() });
    try writer.print("method = {s}\n", .{ request.method() });
    try writer.print("version = {s}\n", .{ request.version() });
    try writer.print("remote = {s}\n", .{ request.remote() });
        for (request.fields()) |*field| {
        try writer.print("{s}: {s}\n", .{ field.name(), field.value(), });
    }

    // We'll use our allocator to read up to 10MB of the request body
    const content = try bodyReader.readAllAlloc(allocator, max_request_body_size);
    // And echo it back
    try writer.print("Content: {s}\n", .{content});
}

fn throwError(req: unit.RequestInfo) !void {
    // This handler demonstrates how you can return errors from a handler;
    //  the `unit.handler` will handle it and cause a failed request to be
    //  returned.  All errors get handled as 5xx server errors.
    // NOTE: for 400 Bad Request type issues, you should write your own
    //  handling that writes a successful response back with the
    //  appropriate status code.
    _=req;
    return error.server_error;
}

fn getItem(req: unit.RequestInfo, item_id: u32) !void {
    // This handler demonstrates taking arguments which are automatically
    //  extracted from the path by the routing layer.
    var writer = unit.responseWriter(req);

    try unit.writeHeaders(req, unit.Status.ok, .{
        .@"Content-Type"="text/plain",
    });

    try writer.print("You asked for item {}", .{ item_id });
}

fn missingPage(req: unit.RequestInfo) !void {
    // This handler is to demonstrate the `**` route
    var writer = unit.responseWriter(req);

    // We'll make a successful response but write a 400 Bad Request
    try unit.writeHeaders(req, unit.Status.bad_request, .{
        .@"Content-Type"="text/plain",
    });
    try writer.print("The page you've asked for doesn't exist", .{});
}
