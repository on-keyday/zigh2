value :u8,
const NONE = 0x0;
const ACK = 0x1;
const END_STREAM = 0x1;
const PADDED = 0x8;
const END_HEADERS = 0x4;
const PRIORITY = 0x20;
const Self = @This();

pub fn is_none(f:Self)  bool {
    return f.value == NONE;
}

pub fn is_ack(f:Self)  bool {
    return f.value == ACK;
}

pub fn is_end_stream(f:Self)  bool {
    return f.value == END_STREAM;
}

pub fn is_padded(f:Self)  bool {
    return f.value & PADDED != 0;
}

pub fn is_end_headers(f:Self)  bool {
    return f.value & END_HEADERS != 0;
}

pub fn is_priority(f:Self)  bool {
    return f.value & PRIORITY != 0;
}

pub fn set_none(f:Self)  Self {
    f.value = NONE;
    return f;
}

pub fn set_ack(f:Self)  Self {
    f.value |= ACK;
    return f;
}

pub fn set_end_stream(f:Self)  Self {
    f.value |= END_STREAM;
    return f;
}

pub fn set_padded(f:Self)  Self {
    f.value |= PADDED;
    return f;
}

pub fn set_end_headers(f:Self)  Self {
    f.value |= END_HEADERS;
    return f;
}

pub fn set_priority(f:Self)  Self {
    f.value |= PRIORITY;
    return f;
}

pub fn init()  Self {
    return Self { .value = NONE };
}