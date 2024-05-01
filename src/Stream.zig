
const frame = @import("frame.zig");
const Client = @import("client.zig").ClientConfig;



pub const State = enum {
    IDLE,
    OPEN,
    CLOSED,
    HALF_CLSOED_REMOTE,
    HALF_CLOSED_LOCAL,
    RESERVED_LOCAL,
    RESERVED_REMOTE,
};

const StreamError = enum {
    InvalidState,
};

pub fn Stream(comptime mutexTy :type) type {
    return struct {
        id :frame.ID,
        state :State,
        client :*Client(mutexTy),

        const Self = @This();

        pub fn init(client :*Client(mutexTy), id :frame.ID, state :State) Self {
            return Self{ .id = id, .state = state, .client = client };
        }

        pub fn sendData(self :*Self, data :[]const u8,eos :bool) !void {
            if(self.state != State.OPEN and self.state != State.HALF_CLSOED_REMOTE) {
                return StreamError.InvalidState;
            }
            {
                self.client.mutex.lock();
                defer self.client.mutex.unlock();
                try self.client.framer.encodeData(self.client.sendBuffer.writer().any(),self.id,data,eos,null);
            }
        }
    };
}
