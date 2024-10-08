const std = @import("std");
const bus = @import("bus.zig");
const bits = @import("const/bits.zig").Bits;
const log= std.log;
const t = std.testing;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
threadlocal var rfp: ?*bus.CanRemoteFrame = null;
threadlocal var dfp: ?*bus.CanDataFrame = null;

threadlocal var isRemoteFrame = false;
threadlocal var isDataFrame = false;
threadlocal var identifier = std.ArrayList(bool).init(allocator);

threadlocal var dFieldLastBit: u8 = undefined;
threadlocal var dLen: u8 = 0;
threadlocal var bitBuff: u8 = 0;
threadlocal var bitCount: u8 = 0;
threadlocal var byteCount: u8 = 0;
threadlocal var dataPos: u8 = 0;

threadlocal var d = [_]u8{0,0};

const ProcessingError = error {
    UnexpectedBit,
    ByteOverflow,
};

pub fn mapBitsToFrames(bit: bool, order: u32, ignoreId: u12) !bus.CanUnion {
    // if sof detected from caller
    std.debug.print("order {d} isrf {} isdf {}\n", .{order, isRemoteFrame, isDataFrame});
    switch (order) {
        0 => {
            // sof is always dominant
            if (bit != false) {
                return error.UnexpectedBit;
            }
        },
        1...12 => {
            // arbitration field
            try identifier.append(bit);
            if (order == 12 and bit == true) {
                // rtr bit recessive -> create remote frame
                isRemoteFrame = true;
            } else if (order == 12 and bit == false) {
                isDataFrame = true;
            }
        },
        13...108 => {
            if (isRemoteFrame) {
                if (rfp == null) {
                    rfp = try allocator.create(bus.CanRemoteFrame);
                    rfp.?.* = createRemoteFrameEmpty();
                    identifier.clearRetainingCapacity();
                }

                try deserializeRemoteFrame(bit, order, rfp.?);
                // last rf bit
                if (43 == order) {
                    isRemoteFrame = false;
                    return bus.CanUnion{ .CanRemoteFrame = rfp.? };
                }
            } else {
                if (dfp == null) {
                    dfp = try allocator.create(bus.CanDataFrame);
                    dfp.?.* = createDataFrameEmpty();
                }
                if (identifier.items.len > 12) {
                    identifier.clearRetainingCapacity();
                }

                try deserializeDataFrame(bit, order, &identifier, ignoreId);
                return bus.CanUnion{ .CanDataFrame = dfp.? };
            }
        },
        else => {
            return error.UnexpectedBit;
        }

    }

    return bus.CanUnion{.CanErrorFrame = undefined};
}

pub fn serializeDataFrame(frame: bus.CanDataFrame) !std.ArrayList(bool) {
    var boolBuff = std.ArrayList(bool).init(allocator);
    // sof is always 1 dominant bit
    try boolBuff.append(false);

    var count4b2: u4 = 0;
    for (0..12) |_| {
        const bit: u12 = frame.arbitration >> (11 - count4b2) & 1;
        try append(bit, &boolBuff);
        count4b2 += 1;
    }

    const dLength: u6 = (frame.control >> 2) & 0xF;

    var count3b: u3 = 0;
    for (0..6) |_| {
        const bit: u6 = frame.control >> (5 - count3b) & 1;
        try append(bit, &boolBuff);
        count3b += 1;
    }

    count3b = 0;

    var byteC: u8 = 0;
    for (frame.data) |byte| {
        if (dLength < byteC) {
            break;
        }
        for (0..8) |_| {
            const bit: u8 = byte >> (7 - count3b) & 1;
            try append(bit, &boolBuff);

            if (count3b != 7) {
                count3b += 1;
            }
        }

        count3b = 0;
        byteC += 1;
    }

    var count4b3: u4 = 0;
    for (0..16) |_| {
        const a: u4 = (15 - count4b3);
        const bit: u16 = (frame.crc >> a) & 1;
        try append(bit, &boolBuff);
        if (count4b3 != 15) {
            count4b3 += 1;
        }
    }

    count3b = 0;
    for (0..2) |_| {
        const a: u1 = @intCast(count3b);
        const bit: u2 = frame.ack >> (1 - a) & 1;
        try append(bit, &boolBuff);
        count3b += 1;
    }

    count3b = 0;
    for (0..7) |_| {
        const bit: u7 = frame.eof >> (6 - count3b) & 1;
        try append(bit, &boolBuff);
        count3b += 1;
    }

    return boolBuff;
}

pub fn deserializeDataFrame(bit: bool, bitPosition: u32, id: *std.ArrayList(bool), ignoreId: u12) !void {
    // remote frame received, send back a data frame
    var f = dfp.?.*;

    if (bitPosition == 0) {
        f.sof = 0;
    }

    if (f.arbitration == 0) {
        for (id.items) |b| {
            f.arbitration <<= 1;
            if (b) {
                f.arbitration |= 1;
            }
        }
    }

    dfp.?.* = f;

    if ((f.arbitration >> 1) == ignoreId) {
        return;
    }

    if (bitPosition <= bits.ControlFieldLastBit.value()) {
        //TODO actually first two bits are reserved, fix that
        // last two bits are reserved, must be dominant
        // if ((bitPosition == bits.ControlFieldLastBit.value()) and bit == false) {
        //     return error.UnexpectedBit;
        // }

        f.control <<= 1;
        if (bit) {
            f.control |= 1;
        }

        if (bitPosition == 18) {
            dLen = ((f.control >> 2) & 0xF) * 8;
            dFieldLastBit = bits.DataFieldFirstBit.value() + dLen;
            dataPos = 19 + dLen;
        }
    }

    if (bitPosition > bits.ControlFieldLastBit.value() and
        bitPosition <= dFieldLastBit) {

        bitBuff = (bitBuff << 1) | @intFromBool(bit);
        bitCount += 1;


        if (bitCount == 8) {
            bitCount = 0;
            d[byteCount] = bitBuff;
            byteCount += 1;
            bitBuff = 0;

            if (byteCount == ((dLen/8) - 1)) {
                return;
            }
        }
    }

    f.data = &d;

    if (bitPosition > dFieldLastBit and
        bitPosition <= (bits.CrcFieldLastBit.value() + dLen)) {
        f.crc <<= 1;

        if (bit) {
            f.crc |= 1;
        }
    }

    if (bitPosition > (bits.CrcFieldLastBit.value() + dLen) and
        bitPosition <= (bits.AckFieldLastBit.value() + dLen)) {
        f.ack <<= 1;

        if (bit) {
            f.ack |= 1;
        }
    }

    if (bitPosition > (bits.AckFieldLastBit.value() + dLen) and
        bitPosition <= bits.EOFLastBit.value() + dLen) {
        if (bit != true) {
            return error.UnexpectedBit;
        }

        f.eof <<= 1;

        if (bit) {
            f.eof |= 1;
        }
    }

    dfp.?.* = f;
}

pub fn deserializeRemoteFrame(bit: bool, bitPosition: u32, rf: *bus.CanRemoteFrame) !void {
    var f = rf.*;
    f.sof = 0;
    f.arbitration = 0x01;

    switch (bitPosition) {
        13...18 => {
            // last two bits are reserved, must be dominant
            if ((bitPosition == 18) and bit != false) {
                return error.UnexpectedBit;
            }

            f.control <<= 1;
            if (bit) {
                f.control |= 1;
            }

        },
        19...34 => {
            f.crc <<= 1;

            if (bit) {
                f.crc |= 1;
            }

        },
        35...36 => {
            //TODO time to check crc and return ack? some callback function?
            f.ack <<= 1;

            if (bit) {
                f.ack |= 1;
                // an ack notifies the node that it has to send one dominant bit
                // and the transmitter node has to wait for the dominant ack bit
                // and continue with the eof + ifs?
            }
        },
        37...44 => {
            if (bit != true) {
                return error.UnexpectedBit;
            }

            f.eof <<= 1;

            if (bit) {
                f.eof |= 1;
            }
        },
        else => {
            return error.ByteOverflow;
        },
    }

   rf.* = f;
}

pub fn serializeRemoteFrame(frame: bus.CanRemoteFrame) !std.ArrayList(bool) {
    var boolBuff = std.ArrayList(bool).init(allocator);
    // sof is always 1 dominant bit
    try boolBuff.append(false);

    var count: u4 = 0;
    for (0..12) |_| {
        const bit: u12 = frame.arbitration >> (11 - count) & 1;
        try append(bit, &boolBuff);
        count += 1;
    }
    var count2: u3 = 0;
    for (0..6) |_| {
        const bit: u6 = frame.control >> (5 - count2) & 1;
        try append(bit, &boolBuff);
        count2 += 1;
    }

    var count3: u4 = 0;
    for (0..16) |_| {
        const a: u4 = (15 - count3);
        const bit: u16 = (frame.crc >> a) & 1;
        try append(bit, &boolBuff);
        if (count3 != 15) {
            count3 += 1;
        }
    }

    count2 = 0;
    for (0..2) |_| {
        const a: u1 = @intCast(count2);
        const bit: u2 = frame.ack >> (1 - a) & 1;
        try append(bit, &boolBuff);
        count2 += 1;
    }

    count2 = 0;
    for (0..7) |_| {
        const bit: u7 = frame.eof >> (6 - count2) & 1;
        try append(bit, &boolBuff);
        count2 += 1;
    }

    return boolBuff;
}

fn append(bit: u16, boolBuff: *std.ArrayList(bool)) !void {
    if (bit == 0) {
        try boolBuff.append(false);
    } else if (bit == 1) {
        try boolBuff.append(true);
    }
}

pub fn createRemoteFrameEmpty() bus.CanRemoteFrame {
    return bus.CanRemoteFrame{
        .sof = 0,
        .arbitration = 0x01,
        .control = 0,
        .crc = 0,
        .ack = 0,
        .eof = 0,
    };
}

pub fn createDataFrameEmpty() bus.CanDataFrame {
    var data = [_]u8{0,0};
    return bus.CanDataFrame{
        .sof = 0,
        .arbitration = 0,
        .control = 0,
        .data = &data,
        .crc = 0,
        .ack = 0,
        .eof = 0,
    };
}

pub fn createRemoteFrame() bus.CanRemoteFrame {
    return bus.CanRemoteFrame {
        .sof = 0b0,
        .arbitration = 0x01,
        .control = 0x04,
        .crc = 0x7FF3,
        .ack = 0x1,
        .eof = 0x7F,
    };
}

pub fn createDataFrame(id: u12) bus.CanDataFrame {
    var data = [_]u8{0b11111000, 0b10};
    return bus.CanDataFrame{
        .sof = 0b0,
        .arbitration = id << 1,
        .control = 0b001000,
        .data = &data,
        .crc = bus.calculateCRC(&data),
        .ack = 0b1,
        .eof = 0x7F,
    };
}

pub fn createInterframeSpace() bus.CanInterframeSpacing {
    return bus.CanInterframeSpacing{
        .intermission = 0b111,
        .suspendTransmission = 0b11111111,
        // bus idle is of arbitrary length
        .busIdle = 0b1111,
    };
}