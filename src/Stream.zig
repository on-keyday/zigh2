
const frame = @import("frame.zig");
const Client = @import("Client.zig");

id :frame.ID,
client :*Client,

const Self = @This();

fn init(id :frame.ID) Self {
    return Self{ .id = id };
}
