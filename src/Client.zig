
const preface  = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const Framer = @import("frame.zig");
const hpack = @import("hpack.zig");

const std = @import("std");
const stream = @import("stream.zig");



const settings = @import("settings.zig");

pub const DummyMutex = struct {
    pub fn lock(_: *DummyMutex) void {}
    pub fn unlock(_: *DummyMutex) void {}
};

pub const SignleThreadClient = ClientConfig(DummyMutex);

pub fn ClientConfig(comptime mutexTy :type) type {
    return struct {
        framer :Framer,
        encodeTable :hpack.Table,
        decodeTable :hpack.Table,
        recvBuffer :Framer.DynamicStream,   
        sendBuffer :Framer.DynamicStream,
        prefaceRecved :bool = false,
        nextID :Framer.ID,
        mutex :mutexTy,

        pub const Stream = stream.Stream(mutexTy);


        const Self = @This();

        fn sendPreface(self:*Self) !void {
            try self.sendBuffer.writer().any().writeAll(preface);
        }

        fn sendWriter(self :*Self) std.io.AnyWriter {
            return self.sendBuffer.writer().any();
        }

        fn recvWriter(self :*Self) std.io.AnyWriter {
            return self.recvBuffer.writer().any();
        }

        fn recvReader(self :*Self) std.io.AnyReader {
            return self.recvBuffer.reader().any();
        }

        pub fn init(alloc :std.mem.Allocator,definedSettings :settings.DefinedSettings,additionalSettings :?[]settings.Setting) !Self {
            var self: Self = undefined;
            self.framer = Framer.init();
            self.encodeTable = hpack.Table.init(alloc,hpack.DEFAULT_TABLE_SIZE);
            self.decodeTable = hpack.Table.init(alloc,hpack.DEFAULT_TABLE_SIZE);
            self.recvBuffer = Framer.DynamicStream.init(alloc);
            self.sendBuffer = Framer.DynamicStream.init(alloc);
            try self.sendPreface();
            try self.framer.encodeSettings(self.sendWriter(),false,definedSettings,additionalSettings);
            self.nextID = Framer.ClientInitialID;
            return self;
        }

        pub fn createStream(self :*Self) !Stream {
            self.mutex.lock();
            defer self.mutex.unlock();
            const id = self.nextID;
            self.nextID = try Framer.nextStreamID(id);
            return Stream.init(self,id,stream.State.IDLE);
        }

        pub const Frames = union(enum) {
            one: Framer.Frame,
            many:std.ArrayList(Framer.Frame),

            pub fn deinit(self: *Self) void {
                switch(self) {
                    Frames.one => self.one.deinit(),
                    Frames.many => {
                        for(self.many.items) |frame| {
                            frame.deinit();
                        }
                        self.many.deinit();
                    }
                }
            }
        };

        pub fn recvPeer(self :*Self,alloc :std.mem.Allocator, data :[]const u8) !?Frames {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.recvWriter().writeAll(data);
            if (!self.prefaceRecved) {
                if(self.recvBuffer.readableLength() < preface.len) {
                    return;
                }
                const expect = try self.recvReader().readBytesNoEof(preface.len);
                if (!std.mem.eql(preface, expect)) {
                    return error.UnexpectedPreface;
                }
                self.prefaceRecved = true;
            }
            var frames :?Frames = null;
            errdefer if(frames) |f|f.deinit(); 
            READ_LOOP:
            while(self.recvBuffer.readableLength() >= 9) {
                const raw_header = try self.recvReader().readBytesNoEof(9);
                var no_unget = false;
                try if(!no_unget) self.recvBuffer.unget(raw_header);
                var tmpr = std.io.fixedBufferStream(raw_header);
                const header = try self.framer.decodeFrameHeader(&tmpr);
                if(self.recvBuffer.readableLength() < header.length) {
                    break :READ_LOOP; // currently, no enough data
                }
                var len = header.length;
                if(header.typ) |t| {
                    if((t == Framer.H2FrameType.HEADERS or t == Framer.H2FrameType.PUSH_PROMISE) and !header.flags.is_end_headers()) {
                        // in this special case, we need to analyze CONTINUATION frames are available for this HEADERS or PUSH_PROMISE frame
                        var slice = self.recvBuffer.readableSlice(header.length);
                        while(slice > 0) {
                            if(slice.len < 9) {
                                break :READ_LOOP; // currently, no enough data
                            }
                            var tmphdr = std.io.fixedBufferStream(slice);
                            const cont_header = try self.framer.decodeFrameHeader(tmphdr.reader().any());
                            if(cont_header.typ != Framer.H2FrameType.CONTINUATION or cont_header.stream_id != header.stream_id) {
                                return error.UnexpectedFrame;
                            }            
                            if(cont_header.length + 9 > slice.len) {
                                break :READ_LOOP; // currently, no enough data
                            }
                            len += 9 + cont_header.length;
                            if(cont_header.flags.is_end_headers()) {
                                break; // ok, we have all headers
                            }
                            slice = slice[9 + cont_header.length..];
                        }
                    }
                }
                no_unget = true; // here, we don't need to unget the header
                const payload = self.recvBuffer.readableSlice(len);
                var tmpp = std.io.fixedBufferStream(payload);
                var frame = try self.framer.decodeFramesWithHeader(header,alloc,tmpp.reader().any(),&self.decodeTable);
                errdefer frame.deinit();
                switch(frames) {
                    null => {
                        frames = .{.one = frame};
                    },
                    Frames.one => {
                        const tmp = std.ArrayList(Frames).init(alloc);
                        errdefer {
                            for(tmp.items) |f| {
                                f.deinit();
                            }
                            tmp.deinit();
                        }
                        try tmp.append(frames.one);
                        frames = null; // for deinit safety
                        try tmp.append(frame);
                        frames = .{.many = tmp};
                    },
                    Frames.many => {
                        try frames.many.append(frame);
                    }
                }
            }
            return frames;
        }
    };
}