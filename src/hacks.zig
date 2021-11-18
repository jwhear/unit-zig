const std = @import("std");
const c = @import("c.zig");

// NGINX Unit does a few... suboptimal things that make the ABI
//  unstable.  If this library is segfaulting or exhibiting weird
//  behavior this is the first place to look: it's likely that an
//  offset is incorrect.
// In the automatically translated C headers, `nxt_unit_request_t`
//  is opaque because it contains `nxt_unit_sptr` (a weird union)
//  and `nxt_unit_field_t` (bitfields).  Given how important this
//  structure is, I've manually mapped it into Zig so that @ptrCast
//  will work.  Whether this mapping works, however, is reliant on
//  the whims of the C compiler you use to compile libunit.a
//
// The contents of this module are the result of my spelunking in
//  Unit's undocumented source code and debugging a lot of segfaults.


/// sptr is a "serialized pointer"--basically a relative pointer.
/// It stores an offset from the location of the pointer itself.
/// As a result it should always be used by reference and never
///  copied elsewhere.
/// Also, it always has a size of 4 bytes instead of the machine
///  word size.
pub fn Sptr(comptime ToType: type) type {
    return extern union {
        const Self = @This();

        offset: u32,

        ///
        pub fn get(self: *const Self) ToType {
            return @intToPtr(ToType, @ptrToInt(self) + self.offset);
        }
    };
}

/// This type is opaque in the auto-translation because it uses bitfields:
/// Original:
///```
///struct nxt_unit_field_s {
///    uint16_t              hash;
///    uint8_t               skip:1;
///    uint8_t               hopbyhop:1;
///    uint8_t               name_length;
///    uint32_t              value_length;
///
///    nxt_unit_sptr_t       name;
///    nxt_unit_sptr_t       value;
///}
///```
///
/// In practice, with the default compilation flags and using GCC,
///  the fields are not reordered and the two bitfields are stored
///  using one byte.  As they seem to be part of the internal rather
///  than external API, I haven't bothered to provide an API for
///  getting or setting them.
/// This is probably consistently true on x86-64 but not for other ABIs.
pub const Field = extern struct {
    //                        offset
    hash: u16,                // 0
    bitfields: u8,            // 2
    name_length: u8,          // 3
    value_length: u32,        // 4
    name_ptr: Sptr([*]u8),    // 8
    value_ptr: Sptr([*]u8),   // 12

    ///
    pub fn name(self: Field) []u8 {
        return self.name_ptr.get()[0..self.name_length];
    }
    ///
    pub fn value(self: Field) []u8 {
        return self.value_ptr.get()[0..self.value_length];
    }
};

/// This type is opaque in the auto-translation
pub const Request = extern struct {
    const Self = @This();

    ///
    method_length: u8,
    ///
    version_length: u8,
    ///
    remote_length: u8,
    ///
    local_length: u8,
    ///
    tls: u8,
    ///
    websocket_handshake: u8,
    ///
    app_target: u8,
    ///
    server_name_length: u32,
    ///
    target_length: u32,
    ///
    path_length: u32,
    ///
    query_length: u32,
    ///
    fields_count: u32,

    // These seem like internal-use fields?
    content_length_field: u32,
    content_type_field: u32,
    cookie_field: u32,
    authorization_field: u32,

    ///
    content_length: u64,

    // Getters provided below for these
    _method: Sptr([*]u8),
    _version: Sptr([*]u8),
    _remote: Sptr([*]u8),
    _local: Sptr([*]u8),
    _server_name: Sptr([*]u8),
    _target: Sptr([*]u8),
    _path: Sptr([*]u8),
    _query: Sptr([*]u8),
    // Not sure what this is exactly, there's no obvious _length field
    _preread_content: Sptr([*]u8),

    // We can't map this as a pointer type: the actual offset is 92, not 96
    _fields_placeholder: u32,

    ///
    pub fn cast(req: ?*c.nxt_unit_request_t) *Request {
        return @ptrCast(*Request, @alignCast(@alignOf(*Request), req.?));
    }

    ///
    pub fn method(self: *const Self) []const u8 {
        return self._method.get()[0 .. self.method_length];
    }
    ///
    pub fn version(self: *const Self) []const u8 {
        return self._version.get()[0 .. self.version_length];
    }
    ///
    pub fn remote(self: *const Self) []const u8 {
        return self._remote.get()[0 .. self.remote_length];
    }
    ///
    pub fn local(self: *const Self) []const u8 {
        return self._local.get()[0 .. self.local_length];
    }
    ///
    pub fn server_name(self: *const Self) []const u8 {
        return self._server_name.get()[0 .. self.server_name_length];
    }
    ///
    pub fn target(self: *const Self) []const u8 {
        return self._target.get()[0 .. self.target_length];
    }
    ///
    pub fn path(self: *const Self) []const u8 {
        return self._path.get()[0 .. self.path_length];
    }
    ///
    pub fn query(self: *const Self) []const u8 {
        return self._query.get()[0 .. self.query_length];
    }

    ///
    pub fn fields(self: *const Self) []const Field {
        var fields_ptr = @ptrCast([*]const Field, &self._fields_placeholder);        return fields_ptr[0 .. self.fields_count];
    }
};
