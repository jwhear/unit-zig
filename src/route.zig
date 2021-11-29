//! This module implements some basic routing functionality based on method
//!  and path only.
//!
//! The high-level API (`route`) will dispatch the request to one of your
//!  handler functions, automatically parsing variables out of the path
//!  and providing them as arguments to the handler function.
//! If you need more customized logic, you can also use the lower-level
//!  `routeMatches` and `routeMatchesEx` functions yourself.
//!

const std = @import("std");
const unit = @import("unit.zig");

///
pub const UNKNOWN:u16 = 0;
///
pub const GET    :u16 = 1 << 0;
///
pub const HEAD   :u16 = 1 << 1;
///
pub const POST   :u16 = 1 << 2;
///
pub const PUT    :u16 = 1 << 3;
///
pub const DELETE :u16 = 1 << 4;
///
pub const CONNECT:u16 = 1 << 5;
///
pub const OPTIONS:u16 = 1 << 6;
///
pub const TRACE  :u16 = 1 << 7;
///
pub const PATCH  :u16 = 1 << 8;
///
pub const ANY    :u16 = GET | HEAD | POST | PUT | DELETE
                      | CONNECT | OPTIONS | TRACE | PATCH;

/// Converts a string to method (u16)
pub fn stringToMethod(str: []const u8) u16 {
    return if (std.mem.eql(u8, str, "GET")) GET
      else if (std.mem.eql(u8, str, "HEAD")) HEAD
      else if (std.mem.eql(u8, str, "POST")) POST
      else if (std.mem.eql(u8, str, "PUT")) PUT
      else if (std.mem.eql(u8, str, "DELETE")) DELETE
      else if (std.mem.eql(u8, str, "CONNECT")) CONNECT
      else if (std.mem.eql(u8, str, "OPTIONS")) OPTIONS
      else if (std.mem.eql(u8, str, "TRACE")) TRACE
      else if (std.mem.eql(u8, str, "PATCH")) PATCH
      else UNKNOWN;
}

///
pub const RouteErrors = enum {
    ///
    no_match,
    ///
    unsupported_variable_type,
};

/// Selects the appropriate route from `routes`.
/// Each entry should look like the following:
///   .{ .methods=GET,      .path="/",               .handler=index },
///   .{ .methods=POST|PUT, .path="/write",          .handler=write },
///   .{ .methods=ANY,      .path="/items/:item_id", .handler=item },
///
/// The handler function will should take a unit.RequestInfo as its
///  first argument; subsequent arguments must match up with variables
///  extracted from the path.  As an example, our `item` handler might
///  look like:
///
/// fn item(req: unit.RequestInfo, item_id: u32) !void {}
///
/// Parameters after the first may be:
///  * Integer types handled by std.fmt.parseInt
///  * []const u8
/// Any other type will result in `error.unsupported_variable_type`
///
pub fn route(req: unit.RequestInfo, routes: anytype) !void {
    inline for (routes) |rt| {
        // The meta-programming in here makes it a bit hairy to read, here's
        //  what we're doing:
        // Get a type representing the arguments of rt.handler
        const Args = std.meta.ArgsTuple(@TypeOf(rt.handler));
        // Create a value of that type
        var args: Args = undefined;
        // The request is always the first argument
        args[0] = req;
        // Allocate an array of string large enough to hold all the other
        //  parameters which will be extracted from the path
        var variables: [args.len-1][]const u8 = undefined;

        if (try routeMatches(unit.Request.cast(req.request),
                             rt.methods, rt.path, &variables)) |captures| {
            if (captures.len != args.len - 1)
                unreachable;

            // The whole gist of this block is the conversion of the strings
            //  in `variables` to the contents of args[1..]
            comptime var i = 1;
            inline while (i < args.len) : (i += 1) {
                const T = @TypeOf(args[i]);
                const variable = captures[i - 1];
                args[i] = switch (@typeInfo(T)) {
                    .Int => try std.fmt.parseInt(T, variable, 10),
                    .Pointer =>
                        if (T == []const u8) variable else error.unsupported_variable_type,
                    else => error.unsupported_variable_type
                };
            }

            // Call the handler function with the arguments
            return callWrapper(rt.handler, args);
        }
    }
    return error.no_match;
}

/// Convenience method for matching a Request.
pub fn routeMatches(req: *const unit.Request, method: u16, pattern: []const u8, variables: [][]const u8) !?[][]const u8 {
    return routeMatchesEx(stringToMethod(req.method()), req.path(),
                          method, pattern, variables);
}

/// Tests whether `req_method` and `path` match against `method` and
///  `pattern`.  If the `pattern` has variables, these are stored in
///  `variables` (slices of `path`).  `variables` must be long enough
///  to store all variable segments of `pattern` or else
///   `error.too_many_variables` is returned.
///
/// Pattern syntax follows these rules for matching:
///  * Both `path` and `pattern` are split on the `/` character into segments
///  * `**` causes a match.  Remaining segments and variables are not processed, so `**` should only occur as the last segment of a pattern.
///  * `*` matches any single segment.
///  * All other segments are matched literally (case sensitive)
///
/// Returns one of an error, `null` (failed to match), or a slice of
///  `variables` representing the variables actually extracted.
/// Callers should make sure the number of variables matches their
///  expectations.
pub fn routeMatchesEx(req_method: u16, path: []const u8,
                      method: u16, pattern: []const u8,
                      variables: [][]const u8) !?[][]const u8 {

    // Method mismatch?
    if (req_method & method == 0) return null;

    // Compare pattern
    var pattern_segments = std.mem.split(u8, pattern, "/");
    var path_segments = std.mem.split(u8, path, "/");
    var variable_i: usize = 0;
    while (pattern_segments.next()) |pattern_segment| {

        // Iterate path_segments in step
        var path_segment = path_segments.next() orelse {
            // We've exhausted path--it's too short
            return null;
        };

        // The ** segment matches all remaining parts of path
        if (std.mem.eql(u8, pattern_segment, "**")) {
            // The rest of path automatically matches
            return variables[0..variable_i];
        }

        // The * segment matches this segment
        else if (std.mem.eql(u8, pattern_segment, "*")) {
            continue;
        }

        // Is this a pattern variable?
        else if (std.mem.startsWith(u8, pattern_segment, ":")) {
            if (variable_i >= variables.len) return error.too_many_variables;
            variables[variable_i] = path_segment;
            variable_i += 1;
        }

        // Otherwise require an exact match
        else if (!std.mem.eql(u8, pattern_segment, path_segment)) {
            return null;
        }
    }

    // If we failed to consume all of path, fail
    if (path_segments.next() != null) return null;

    // Successful match
    return variables[0..variable_i];
}

//Workaround for https://github.com/ziglang/zig/issues/5170
fn callWrapper(func: anytype, args: anytype) !void {
    try @call(.{}, func, args);
}

const testing_null_match: ?[][]const u8 = null;
test "routeMatchesEx success" {
    var variables: [9][]const u8 = undefined;
    var extracted = try routeMatchesEx(
        GET, "/items/16/name",
        GET, "/items/:item_id/:facet", &variables);
    try std.testing.expect(extracted != null);
    try std.testing.expectEqual(extracted.?.len, 2);
    try std.testing.expectEqualStrings(extracted.?[0], "16");
    try std.testing.expectEqualStrings(extracted.?[1], "name");
}

test "routeMatchesEx short failure" {
    // Make sure a short pattern doesn't match a longer path
    var variables: [9][]const u8 = undefined;
    try std.testing.expectEqual(testing_null_match, try routeMatchesEx(
        GET, "/items/16/name",
        GET, "/items/*", &variables));
}

test "routeMatchesEx **" {
    // Unless there's a ** of course
    var variables: [9][]const u8 = undefined;
    var extracted = try routeMatchesEx(
        GET, "/items/16/name",
        GET, "/items/**", &variables);
    try std.testing.expect(extracted != null);
    try std.testing.expectEqual(extracted.?.len, 0);
}

test "routeMatchesEx method mismatch" {
    // Method mismatch
    var variables: [9][]const u8 = undefined;
    try std.testing.expectEqual(testing_null_match, try routeMatchesEx(
        GET | POST | PUT, "/items/16/name",
        HEAD, "/items/**", &variables));

}
