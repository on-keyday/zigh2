
const preface  = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const Framer = @import("frame.zig");
const hpack = @import("hpack.zig");

const std = @import("std");


const settings = @import("settings.zig");

pub const DummyMutex = struct {
    pub fn init() DummyMutex {
        return .{};
    }
    pub fn lock(_: *DummyMutex) void {}
    pub fn tryLock(_: *DummyMutex) bool { return true; }
    pub fn unlock(_: *DummyMutex) void {}
    pub fn deinit(_: *DummyMutex) void {}
};

pub const SignleThreadClient = Connection(DummyMutex);
const frame = Framer;
const Frames = union(enum) {
    one: Framer.Frame,
    many:std.ArrayList(Framer.Frame),

    pub fn deinit(self: *Frames) void {
        switch(self.*) {
            .one => |*o| o.deinit(),
            .many => |*m| {
                for(m.items) |*f| {
                    f.deinit();
                }
                self.many.deinit();
            }
        }
    }
};

pub const State = enum {
    IDLE,
    OPEN,
    CLOSED,
    HALF_CLSOED_REMOTE,
    HALF_CLOSED_LOCAL,
    RESERVED_LOCAL,
    RESERVED_REMOTE,
};

const StreamError = error {
    InvalidState,
};

fn Window(comptime lockTy :type) type {
    if(lockTy == DummyMutex) {
        return struct {
            window :u32,

            const Self = @This();

            pub fn get(self :*Self) u32 {
                return self.window;
            }

            pub fn set(self :*Self, size :u32) void {
                self.window = size;
            }

            pub fn init(window :u32) Self {
                return Self{ .window = window};
            }

            pub fn can_consume(self :*Self, size :usize) bool {
                return size <= @as(usize, self.window);
            }

            pub fn consume(self :*Self, size :usize) !void {
                if(!self.can_consume(size)) {
                    return error.WindowSizeError;
                }
                self.window -= @intCast(size);
            }

            pub fn increase(self :*Self, size :u31) !void {
                if(self.window + size > 0x7fffffff) {
                    return error.WindowSizeError;
                }
                self.window += size;
            }   
        };
    } else {
        return struct {
            window :std.atomic.Value(u32),

            const Self = @This();

            pub fn get(self :*const Self) u32 {
                return self.window.load(std.builtin.AtomicOrder.seq_cst);
            }

            // we can use this function without lock
            pub fn set(self :*Self, size :u32) void {
                self.window.store(size,std.builtin.AtomicOrder.seq_cst);
            }

            pub fn init(window :u32) Self {
                return Self{ .window = std.atomic.Value(u32).init(window)};
            }

            // we can use this function without lock
            pub fn can_consume(self :*const Self, size :usize) bool {
                return size <= @as(usize,self.get());
            }

            // at here, we should lock the window
            pub fn consume(self :*Self, size :u32) !void {
                if(!self.can_consume(size)) {
                    return error.WindowSizeError;
                }
                self.window.fetchSub(@intCast(size),std.builtin.AtomicOrder.seq_cst);
            }

            // at here, we should lock the window
            pub fn increase(self :*Self, size :u31) !void {
                if(self.window + size  > 0x7fffffff) {
                    return error.WindowSizeError;
                }
                self.window.fetchAdd(size,std.builtin.AtomicOrder.seq_cst);
            }   
        };
    }
}

pub const RecvHeader = struct {
    /// HEADERS or PUSH_PROMISE
    from :frame.H2FrameType, 
    header :hpack.Header,

    pub fn deinit(self: *RecvHeader) void {
        self.header.deinit();
    }
};

pub fn StreamConfig(comptime mutexTy :type) type {
    return struct {
        const Conn = Connection(mutexTy);
        id :frame.ID,
        state :State,
        conn :*Conn,
        send_window :Window(mutexTy),
        recv_window :Window(mutexTy),
        recv_buffer :frame.DynamicStream,
        mutex :mutexTy,
        ref_count :std.atomic.Value(u32),
        headers :std.fifo.LinearFifo(RecvHeader,.Dynamic),
        err_code :?u32,

        const Self = @This();

        pub fn incref(self :*Self) void {
            _ = self.ref_count.fetchAdd(1,std.builtin.AtomicOrder.seq_cst);
        }

        pub fn init(conn :*Conn, id :frame.ID, state :State) !*Self {
            var self = try conn.alloc.create(Self);
            self.conn = conn;
            self.incref();
            self.id = id;
            self.state = state;
            self.send_window = Window(mutexTy).init(if(conn.peerSettings) |s| s.initialWindowSize else settings.initialWindowSize);
            self.recv_window = Window(mutexTy).init(conn.localSettings.initialWindowSize);
            self.recv_buffer = frame.DynamicStream.init(conn.alloc);
            self.mutex = mutexTy.init();
            self.ref_count = std.atomic.Value(u32).init(1);
            self.headers = std.fifo.LinearFifo(RecvHeader,.Dynamic).init(conn.alloc);
            self.err_code = null;
            return self;
        }

        /// https://www.rfc-editor.org/rfc/rfc9113.html#name-data
        /// DATA frames are subject to flow control and can only be sent when a stream is in the "open" or "half-closed (remote)" state.
        pub fn sendData(self :*Self, data :[]const u8,eos :bool) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.conn.mutex.lock();
            defer self.conn.mutex.unlock();
            if(self.conn.goawayCode) {
                self.state = State.CLOSED;
                return error.GoawayReceived;
            }
            if(self.state != State.OPEN and self.state != State.HALF_CLSOED_REMOTE) {
                return StreamError.InvalidState;
            }
            if(!self.send_window.can_consume(data.len)) {
                return error.WindowSizeError;
            }
            if(!self.conn.send_window.can_consume(data.len)){
                return error.WindowSizeError;
            }
            try self.conn.framer.encodeData(self.conn.sendBuffer.writer().any(),self.id,data,eos,null);
            try self.conn.send_window.consume(data.len);
            try self.send_window.consume(data.len);
            if(eos) {
                if(self.state == State.OPEN) {
                    // open - send ES -> half-closed (local)
                    self.state = State.HALF_CLOSED_LOCAL;
                }
                else if(self.state == State.HALF_CLSOED_REMOTE) {
                    // half-closed (remote) - send ES -> closed
                    self.state = State.CLOSED;
                }
            }
        }

        /// https://www.rfc-editor.org/rfc/rfc9113.html#name-headers
        /// HEADERS frames can be sent on a stream in the "idle", "reserved (local)", "open", or "half-closed (remote)" state.
        pub fn sendHeader(self :*Self, alloc :std.mem.Allocator ,hdr :hpack.Header,eos :bool) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.conn.mutex.lock();
            defer self.conn.mutex.unlock();
            if(self.conn.goawayCode)|_| {
                self.state = State.CLOSED;
                return error.GoawayReceived;
            }
            if(self.state != State.IDLE and self.state != State.RESERVED_LOCAL
                and self.state != State.HALF_CLSOED_REMOTE and self.state != State.OPEN) {
                return StreamError.InvalidState;
            }
            try self.conn.framer.encodeHeaders(alloc,self.conn.sendWriter(),self.id,eos,hdr,&self.conn.encodeTable,null,null);
            if(self.state == State.IDLE) {
                // idle or reserved (local) - send H -> open
                self.state = State.OPEN;
            }
            if(self.state == State.RESERVED_LOCAL) {
                // reserved (local) - send H -> half-closed (remote)
                self.state = State.HALF_CLSOED_REMOTE;
            }
            if(eos) {
                if(self.state == State.OPEN) {
                    // open - send ES -> half-closed (local)
                    self.state = State.HALF_CLOSED_LOCAL;
                }
                else if(self.state == State.HALF_CLSOED_REMOTE) {
                    // half-closed (remote) - send ES -> closed
                    self.state = State.CLOSED;
                }
            }
        }

        pub fn sendWindowUpdate(self :*Self,increment :u31) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.conn.mutex.lock();
            defer self.conn.mutex.unlock();
            if(self.conn.goawayCode)|_| {
                self.state = State.CLOSED;
                return error.GoawayReceived;
            }
            const curWindow = self.recv_window.get();
            try self.recv_window.increase(increment);
            errdefer self.recv_window.set(curWindow);
            const curConnWindow = self.conn.recv_window.get();
            try self.conn.recv_window.increase(increment);
            errdefer self.conn.recv_window.set(curConnWindow);
            try self.conn.framer.encodeWindowUpdate(self.conn.sendWriter(),self.id,increment);
        }

        pub fn close(self :*Self,code :u32) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.conn.mutex.lock();
            defer self.conn.mutex.unlock();
            if(self.conn.goawayCode) |_| {
                self.state = State.CLOSED;
                return;
            }
            if(self.state == State.CLOSED or self.state == State.IDLE) {
                return;
            }
            try self.conn.framer.encodeRstStream(self.conn.sendWriter(),self.id,code);
            self.state = State.CLOSED;
        }

        pub fn deinit(self: *Self) !void {
            var d :?anyerror = null;
            if(self.state != State.CLOSED) {
                self.close(0) catch |err| {
                    d = err;
                };
            }
            if(self.ref_count.fetchSub(1,std.builtin.AtomicOrder.seq_cst) == 1) {
                self.recv_buffer.deinit();
                self.mutex.deinit();
                for(self.headers.buf) |*h| {
                    h.deinit();
                }
                self.headers.deinit();
                var alloc = self.conn.alloc;
                self.conn.deinit(); // for here, we don't need to lock the connection
                alloc.destroy(self);
            }
            if(d) |err| {
                return err;
            }
        }        

        /// can be called with lock by connection
        /// f is only borrowed
        /// USER MUST NOT CALL THIS FUNCTION!!!
        pub fn handleFrame(self :*Self, f :*frame.Frame) !void {
            var trylocked = false;
            if(self.mutex.tryLock()) {
                trylocked = true;
            }
            defer if(trylocked) self.mutex.unlock();
            switch(f.payload) {
                .data => |d| {
                    try self.conn.recv_window.consume(d.data.?.items.len);
                    try self.recv_window.consume(d.data.?.items.len);
                    if(self.state != State.OPEN and self.state != State.HALF_CLOSED_LOCAL) {
                        return StreamError.InvalidState;
                    }
                    try self.recv_buffer.writer().any().writeAll(d.data.?.items);
                    if(f.header.flags.is_end_stream()) {
                        if(self.state == State.OPEN) {
                            // open - recv ES -> half-closed (remote)
                            self.state = State.HALF_CLSOED_REMOTE;
                        }
                        else if(self.state == State.HALF_CLOSED_LOCAL) {
                            // half-closed (local) - recv ES -> closed
                            self.state = State.CLOSED;
                        }
                    }
                },
                .window_update => |w| {
                    try self.send_window.increase(w.increment);
                },
                .headers => |*h| {    
                    if(self.state != State.IDLE and self.state != State.RESERVED_REMOTE 
                       and self.state != State.HALF_CLOSED_LOCAL and self.state != State.OPEN) {
                        return StreamError.InvalidState;
                    }
                    try self.headers.writeItem(RecvHeader{.from =frame.H2FrameType.HEADERS,.header =  h.header.?});
                    h.header = null; // for deinit safety    
                    if(self.state == State.IDLE ) {
                        // idle or reserved (remote) - recv H -> open
                        self.state = State.OPEN;
                    }
                    if(self.state == State.RESERVED_REMOTE) {
                        // reserved (remote) - recv H -> half-closed (local)
                        self.state = State.HALF_CLOSED_LOCAL;
                    }
                    if(f.header.flags.is_end_stream()) {
                        if(self.state == State.OPEN) {
                            // open - recv ES -> half-closed (remote)
                            self.state = State.HALF_CLSOED_REMOTE;
                        }
                        else if(self.state == State.HALF_CLOSED_LOCAL) {
                            // half-closed (local) - recv ES -> closed
                            self.state = State.CLOSED;
                        }
                    }
                },
                .push_promise => |*p| {

                    if(self.state != State.IDLE) {
                        return StreamError.InvalidState;
                    }
                    try self.headers.writeItem(RecvHeader{.from =frame.H2FrameType.PUSH_PROMISE,.header =  p.header.?});
                    p.header = null; // for deinit safety
                    self.state = State.RESERVED_REMOTE;
                },
                .priority => {
                    // not implemented
                },
                .rst_stream => |r| {
                    self.err_code = r.error_code;
                    self.state = State.CLOSED;
                },
                .opaque_data => {}, // not known frame, ignore
                else => unreachable, // if in here, it's a bug
            }
        }

        pub fn recvData(self :*Self,buf :[]u8) ?usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            if(self.recv_buffer.readableLength() == 0) {
                if(self.state == State.CLOSED or self.state == State.HALF_CLSOED_REMOTE) {
                    return null;
                }
                return 0;
            }
            return self.recv_buffer.read(buf);          
        }

        pub fn readHeader(self :*Self) !?RecvHeader {
            self.mutex.lock();
            defer self.mutex.unlock();
            if(self.headers.readableLength() == 0) {
                return null;
            }
            return self.headers.readItem();
        }
    };
}


pub fn Connection(comptime mutexTy :type) type {
    return struct {
        framer :Framer,
        encodeTable :hpack.Table,
        decodeTable :hpack.Table,
        recvBuffer :Framer.DynamicStream,   
        sendBuffer :Framer.DynamicStream,
        prefaceRecved :bool = false,
        nextID :Framer.ID,
        send_window :Window(mutexTy),
        recv_window :Window(mutexTy),
        streams :std.AutoArrayHashMap(Framer.ID,*Stream),
        mutex :mutexTy,
        localSettings :settings.DefinedSettings,
        settingsAcked :bool = false,
        peerSettings :?settings.DefinedSettings,
        ref_count :std.atomic.Value(u32),
        isClient :bool = true,  // for now, we only support client
        alloc :std.mem.Allocator, // shared with all streams
        /// When a stream transitions out of the "idle" state, 
        /// all streams in the "idle" state that might have been opened 
        /// by the peer with a lower-valued stream identifier immediately 
        /// transition to "closed". That is, an endpoint may skip a stream identifier, 
        /// with the effect being that the skipped stream is immediately closed.
        peerOpenMax :frame.ID,

        finalStreamID :?Framer.ID = null,
        goawayCode :?u32 = null,
        debugData :?hpack.U8Array = null,

        pub const Stream = StreamConfig(mutexTy);


        const Self = @This();

        pub fn deinit(self :*Self) void {
            if(self.ref_count.fetchSub(1,std.builtin.AtomicOrder.seq_cst) != 1) {
                return; // nothing to do
            }
            self.encodeTable.deinit();
            self.decodeTable.deinit();
            self.recvBuffer.deinit();
            self.sendBuffer.deinit();
            self.mutex.deinit();
            var iter = self.streams.iterator();
            while(iter.next()) |entry| {
                var stream :*Stream= entry.value_ptr.*;
                stream.state = State.CLOSED; // at here, all streams are closed
                stream.deinit() catch {
                    // ignore, nothing can do
                };
            }
            self.streams.deinit();
            self.alloc.destroy(self); // finally, destroy the connection
        }


        fn sendPreface(self:*Self) !void {
            try self.sendBuffer.writer().any().writeAll(preface);
        }

        pub fn sendWriter(self :*Self) std.io.AnyWriter {
            return self.sendBuffer.writer().any();
        }

        fn recvWriter(self :*Self) std.io.AnyWriter {
            return self.recvBuffer.writer().any();
        }

        fn recvReader(self :*Self) std.io.AnyReader {
            return self.recvBuffer.reader().any();
        }

        /// get the send buffer
        /// the buffer's ownership is transferred to the caller
        /// caller must call deinit() to release the buffer
        pub fn getSendBuffer(self :*Self) frame.DynamicStream {
            self.mutex.lock();
            defer self.mutex.unlock();
            const res = self.sendBuffer;
            self.sendBuffer = Framer.DynamicStream.init(self.alloc);
            return res;
        }

        pub fn init(alloc :std.mem.Allocator,client :bool ,definedSettings :settings.DefinedSettings,additionalSettings :?[]settings.Setting) !*Self {
            var self :*Self = try alloc.create(Self);
            self.* = undefined;
            self.alloc = alloc;
            errdefer self.deinit();
            self.mutex = mutexTy.init();
            if(definedSettings.maxFrameSize < settings.initialMaxFrameSize) {
                return error.InvalidMaxFrameSize;
            }
            self.recvBuffer = Framer.DynamicStream.init(alloc);
            self.sendBuffer = Framer.DynamicStream.init(alloc);
            self.framer = Framer.init();
            
            // set the max frame size
            self.framer.peer_max_frame_size = settings.initialMaxFrameSize;
            self.framer.local_max_frame_size = definedSettings.maxFrameSize;

            // write preface and settings
            if(client) {   
                try self.sendPreface();
                self.prefaceRecved = true; // no preface will receive from the server
            }
            try self.framer.encodeSettings(self.sendWriter(),false,definedSettings,additionalSettings);
            
            // set the local settings
            self.localSettings = definedSettings;
            self.peerSettings = null;

            // set the window size
            self.recv_window = Window(mutexTy).init(definedSettings.initialWindowSize);
            self.send_window = Window(mutexTy).init(settings.initialWindowSize);
            
            // set the table
            self.decodeTable = hpack.Table.init(alloc,definedSettings.headerTableSize);
            self.encodeTable = hpack.Table.init(alloc,hpack.DEFAULT_TABLE_SIZE);
           

            self.settingsAcked = false;
            self.nextID = if(client) frame.ClientInitialID else frame.ServerInitialID;

            self.ref_count = std.atomic.Value(u32).init(1);

            self.streams = std.AutoArrayHashMap(Framer.ID,*Stream).init(alloc);

            self.isClient = client;

            self.peerOpenMax = 0;

            self.goawayCode = null;
            self.finalStreamID = null;
            self.debugData = null;

            return self;
        }

        /// return the new stream
        /// the stream is not opened yet
        /// send must call deinit() to release the stream
        pub fn createStream(self :*Self) !*Stream {
            self.mutex.lock();
            defer self.mutex.unlock();
            const id = self.nextID;
            self.nextID = try Framer.nextStreamID(id);
            const stream = try Stream.init(self,id,State.IDLE);
            self.streams.put(id,stream) catch |err| {
                try stream.deinit();
                return err;
            };
            stream.incref(); // for stream map
            return stream;
        }

        pub fn sendGoaway(self :*Self,code :u32, lastStreamID :Framer.ID, debugData :?[]const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.framer.encodeGoaway(self.sendBuffer.writer().any(),lastStreamID,code,debugData);
            self.goawayCode = code;
            self.finalStreamID = lastStreamID;
            if(debugData) |d| {
                self.debugData = try hpack.u8ArrayFromStr(self.alloc,d);
            }
        }

       


        fn recvPeer(self :*Self,alloc :std.mem.Allocator, data :[]const u8) !?Frames {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.recvBuffer.writer().any().writeAll(data);
            if (!self.prefaceRecved) {
                if(self.recvBuffer.readableLength() < preface.len) {
                    return null; // currently, no enough data
                }
                const expect = try self.recvReader().readBytesNoEof(preface.len);
                if (!std.mem.eql(u8,preface, &expect)) {
                    return error.UnexpectedPreface;
                }
                self.prefaceRecved = true;
            }
            var frames :?Frames = null;
            errdefer if(frames) |*f|f.deinit(); 
            var r = self.recvBuffer.reader().any();
            READ_LOOP:
            while(self.recvBuffer.readableLength() >= 9) {
                const raw_header = try r.readBytesNoEof(9);
                var no_unget = false;
                defer if(!no_unget) self.recvBuffer.unget(&raw_header) catch {
                    // ignore, nothing can do
                };
                var tmpr = std.io.fixedBufferStream(&raw_header);
                const header = try self.framer.decodeFrameHeader(tmpr.reader().any());
                if(self.recvBuffer.readableLength() < header.length) {
                    break :READ_LOOP; // currently, no enough data
                }
                switch(header.typ) { 
                    .typ => |t| {
                        if((t == Framer.H2FrameType.HEADERS or t == Framer.H2FrameType.PUSH_PROMISE) and !header.flags.is_end_headers()) {
                            // in this special case, we need to analyze CONTINUATION frames are available for this HEADERS or PUSH_PROMISE frame
                            var slice = self.recvBuffer.readableSlice(header.length);
                            while(slice.len > 0) {
                                if(slice.len < 9) {
                                    break :READ_LOOP; // currently, no enough data
                                }
                                var tmphdr = std.io.fixedBufferStream(slice);
                                const cont_header = try self.framer.decodeFrameHeader(tmphdr.reader().any());
                                const cont_ty = switch(cont_header.typ) {
                                    .typ => |ty| ty,
                                    else => return error.UnexpectedFrame,
                                };
                                if(cont_ty != Framer.H2FrameType.CONTINUATION or cont_header.stream_id != header.stream_id) {
                                    return error.UnexpectedFrame;
                                }            
                                if(cont_header.length + 9 > slice.len) {
                                    break :READ_LOOP; // currently, no enough data
                                }
                                if(cont_header.flags.is_end_headers()) {
                                    break; // ok, we have all headers
                                }
                                slice = slice[9 + cont_header.length..];
                            }
                        }
                    },
                    else => {},
                }
                no_unget = true; // here, we don't need to unget the header
                var f = try self.framer.decodeFramesWithHeader(header,alloc,r,&self.decodeTable);
                errdefer f.deinit();
                if(frames) |*frms| {
                    switch(frms.*) {
                        .one => |o| {
                            var tmp = std.ArrayList(frame.Frame).init(alloc);
                            errdefer {
                                for(tmp.items) |*t| {
                                    t.deinit();
                                }
                                tmp.deinit();
                            }
                            try tmp.append(o);
                            frames = null; // for deinit safety
                            try tmp.append(f);
                            frames = .{.many = tmp};
                        },
                        .many => |*m| {
                            try m.append(f);
                        },
                    }
                } else {
                    frames = .{.one = f};
                }
            }
            return frames;
        }

        fn setPeerSettings(self :*Self, s :[]settings.Setting) !void {
            const oldSettings = self.peerSettings;
            var newSettings =settings.DefinedSettings{};
            if (oldSettings) |old| {
                newSettings = old;
            }
            for(s) |setting| {
                switch(setting.id) {
                    settings.SETTINGS_HEADER_TABLE_SIZE => {
                        newSettings.headerTableSize = setting.value;
                        self.encodeTable.update_max_size(setting.value);
                    },
                    settings.SETTINGS_ENABLE_PUSH => {
                        if(setting.value != 0 and setting.value != 1) {
                            // Any value other than 0 or 1 MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
                            return error.InvalidSettingValue;
                        }
                        newSettings.enablePush = setting.value == 1;
                    },
                    settings.SETTINGS_INITIAL_WINDOW_SIZE => {
                        // Values above the maximum flow-control window size of 2^31-1 MUST be treated as a connection error (Section 5.4.1) of type FLOW_CONTROL_ERROR.
                        if(setting.value > 0x7fffffff) {
                            return error.InvalidSettingValue;
                        }
                        const oldWindow = newSettings.initialWindowSize;
                        const newWindow = setting.value;
                        var iter = self.streams.iterator();
                        while (iter.next()) |it| {
                            var stream :*Stream = it.value_ptr.*;
                            // NOTE(on-keyday): 
                            // at here connection lock is already acquired.
                            // if tryLock is succeed, we have to unlock it
                            // otherwsize, lock is not acquired but the stream operation will blocked by
                            // connection lock, so we don't need to lock it
                            var tryLocked = false;
                            if(stream.mutex.tryLock()) {
                                tryLocked = true;
                            }
                            defer if(tryLocked) stream.mutex.unlock();                            
                            stream.send_window.set(newWindow - (oldWindow - stream.send_window.get()));
                        }
                        newSettings.initialWindowSize = @intCast(setting.value);
                    },
                    settings.SETTINGS_MAX_CONCURRENT_STREAMS => {
                        newSettings.maxConcurrentStreams = setting.value;
                    },
                    settings.SETTINGS_MAX_FRAME_SIZE => {
                        if(setting.value < settings.initialMaxFrameSize or setting.value > 0xffffff) {
                            return error.InvalidSettingValue;
                        }
                        newSettings.maxFrameSize = @intCast(setting.value);
                        self.framer.peer_max_frame_size = @intCast(setting.value);
                    },
                    else => {}, // ignore
                }
            }
        }
 
        fn handleFrame(self :*Self, f :*Framer.Frame) !void {
            if(!self.settingsAcked) { // first frame must be SETTINGS
                if(self.peerSettings) |_| {
                    // nothing to do
                } 
                else {
                    if(f.header.typ.getType()) |t| {
                        if(t != Framer.H2FrameType.SETTINGS and t != Framer.H2FrameType.PING 
                        and t != Framer.H2FrameType.GOAWAY and t != Framer.H2FrameType.WINDOW_UPDATE) {
                            return error.UnexpectedFrame;
                        }                        
                    } else {
                        return error.UnexpectedFrame;
                    }
                }
            }
            if(f.header.stream_id == Framer.CONNECTION) {
                switch(f.payload) {
                    .ping => |p| {
                        if (f.header.flags.is_ack()) {
                            // ignore
                        } else {
                            // let's pong
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            try self.framer.encodePing(self.sendWriter(),p,true);
                        }
                    },
                    .window_update =>|w| {
                        self.mutex.lock();
                        defer self.mutex.unlock();
                        try self.send_window.increase(w.increment);
                    },
                    .settings => |s| {
                        if(f.header.flags.is_ack()) {
                            self.settingsAcked = true;
                        }
                        else {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            try self.setPeerSettings(s.?.items);
                            // send ack
                            try self.framer.encodeSettings(self.sendWriter(),true,null,null);
                        }
                    },
                    .goaway => |*s| {
                        self.mutex.lock();
                        defer self.mutex.unlock();
                        self.goawayCode = s.error_code;
                        self.finalStreamID = s.last_stream_id;
                        self.debugData = s.debug_data;   
                        s.debug_data = null; // for deinit safety                     
                    },
                    .opaque_data => {}, // not known frame, ignore
                    else => unreachable,
                 }
                return;
            }
            self.mutex.lock();
            defer self.mutex.unlock();
            if(f.header.typ.getType()) |p| if(p == frame.H2FrameType.PUSH_PROMISE and !self.localSettings.enablePush) {
                return error.PushPromiseNotEnabled;
            };
            const exists = self.streams.get(f.header.stream_id);
            if(exists) |st| {
                var stream :*Stream = st;
                try stream.handleFrame(f);
                return;
            }
            if(f.header.stream_id <= self.peerOpenMax) {
                return error.StreamClosed;
            }
            const new_stream = try Stream.init(self,f.header.stream_id,State.IDLE);
            var no_deinit = false;
            errdefer if(!no_deinit) new_stream.deinit() catch {
                // ignore, nothing can do
            };
            try self.streams.put(f.header.stream_id,new_stream);
            no_deinit = true;
            try new_stream.handleFrame(f);
        }

        pub fn handlePeer(self :*Self,alloc :std.mem.Allocator, data :[]const u8) !void {
            var frames = try self.recvPeer(alloc,data);
            if(frames) |*f| {
                defer f.deinit();
                switch(f.*) {
                    .one => |*o|  {
                        try self.handleFrame(o);
                    },
                    .many => {
                        for(f.many.items) |*f2| {
                            try self.handleFrame(f2);
                        }
                    }
                }
            }
        }
    };
}