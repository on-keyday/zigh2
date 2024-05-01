
const std = @import("std");

// constant u32 array
// from https://github.com/on-keyday/utils/main/src/include/fnet/util/hpack/hpack_huffman_table.h
const raw_table = [_]u32{
    229377,65584,1441795,131250,1343493,884742,2147483680,262210,295003,327802,360631,393244,426113,589838,1114127,557072,2147483681,2147483682,622623,753684,688319,2686998,2147483683,2392088,2752537,852162,2147483684,2147483685,1277981,1212446,2147483686,1048659,1245217,2147483687,1179683,2147483688,2147483689,2147483690,2147483691,2359336,2147483692,1409066,2147483693,2147483694,1933357,1835054,1802287,2147483695,4882481,1736754,1703987,2147483696,2147483697,4816950,2147483698,2147483699,1900601,2147483700,2147483701,2064444,2031677,2147483702,2147483703,2129984,2147483704,2147483705,2195534,2228390,2261168,2883654,2850887,2147483706,2147483707,2424972,2457742,4390988,4784205,2147483708,4980815,4718672,2818129,2147483709,2147483710,2147483711,4358229,2147483712,2147483713,2147483714,2949209,2147483715,2147483716,3506268,3276893,3178590,3145823,2147483717,2147483718,3244130,2147483719,2147483720,3407973,3375206,2147483721,2147483722,3473513,2147483723,2147483724,3768428,3670125,3637358,2147483725,2147483726,3735665,2147483727,2147483728,3899508,3866741,2147483729,2147483730,3965048,2147483731,2147483732,5308539,4161660,4128893,2147483733,2147483734,4292736,2147483735,4325506,2147483736,2147483737,2147483738,2147483739,4423870,6389896,9371785,9044106,13435019,2147483740,6324365,2147483741,6291599,2147483742,4849809,2147483743,2147483744,2147483745,2147483746,5243030,5079191,2147483747,5144729,5111962,2147483748,2147483749,2147483750,5210270,2147483751,2147483752,5636257,2147483753,5701795,5406884,2147483754,2147483755,5570727,5537960,2147483756,2147483757,5669035,2147483758,2147483759,2147483760,5963951,2147483761,5931185,2147483762,5898419,2147483763,2147483764,2147483765,2147483766,6127800,6095033,2147483767,2147483768,6193340,2147483769,2147483770,2147483771,2147483772,2147483773,2147483774,2147483648,6422807,6652101,6488441,6521246,9863368,9765065,9666762,2147483649,6684986,6717666,6750570,6783379,6816184,7569617,7274706,7045331,6947326,7012565,2147483650,2147483651,7176408,7143641,2147483652,2147483653,7241948,2147483654,2147483655,7962847,7831776,7799009,2147483656,7438732,10125540,7504358,10060006,2147483657,7602426,7635211,7667986,7700982,8421612,7897325,2147483658,2147483659,7930096,2147483660,2147483661,2147483662,8093940,8061173,2147483663,2147483664,8159480,2147483665,2147483666,8519931,8356092,8323325,2147483667,2147483668,8487168,2147483669,16777474,2147483670,2147483671,8651013,8618246,2147483672,2147483673,8716553,2147483674,2147483675,8880396,8847629,2147483676,2147483677,8945936,2147483678,2147483679,15040787,2147483775,9077172,9339158,2147483776,9175412,10879257,9535770,9273817,9503004,2147483777,2147483778,10748191,12714272,11305249,2147483779,2147483780,9699620,9634085,2147483781,2147483782,2147483783,10256681,2147483784,9830699,2147483785,2147483786,9994542,9961775,2147483787,2147483788,10092850,2147483789,2147483790,2147483791,10453302,10223927,2147483792,2147483793,2147483794,11469115,10649916,10551613,10518846,2147483795,11174208,2147483796,2147483797,10617155,2147483798,2147483799,11075910,11010375,2147483800,10781137,11632970,11272523,2147483801,11370829,11206990,11043151,2147483802,2147483803,2147483804,11141459,2147483805,2147483806,2147483807,11338071,2147483808,2147483809,2147483810,2147483811,11796828,11764061,2147483812,12091743,11698528,11600225,2147483813,2147483814,11993444,2147483815,12058982,2147483816,2147483817,12026217,2147483818,13664619,14713196,14221677,2147483819,2147483820,2147483821,2147483822,12616050,12550515,2147483823,14778741,12484982,12321143,2147483824,2147483825,12878202,12779899,12583292,2147483826,14319998,2147483827,2147483828,2147483829,12681602,2147483830,2147483831,13402501,2147483832,12845447,2147483833,2147483834,13107594,13074827,2147483835,13500813,13173134,2147483836,2147483837,13468049,2147483838,2147483839,13992340,13894037,13795734,13369751,2147483840,2147483841,2147483842,2147483843,2147483844,15532445,2147483845,15565215,15434144,2147483846,13697505,15663523,14254500,2147483847,13861286,2147483848,2147483849,14352809,14188970,2147483850,14025159,14057962,14090751,14156207,2147483851,2147483852,2147483853,2147483854,2147483855,2147483856,2147483857,14614967,2147483858,16187833,15106490,14647739,14582204,2147483859,2147483860,2147483861,15073728,2147483862,15303106,2147483863,15368644,14877125,2147483864,2147483865,15860168,15008201,2147483866,2147483867,2147483868,2147483869,15991246,15204815,2147483870,2147483871,15335890,2147483872,2147483873,2147483874,15466966,2147483875,2147483876,2147483877,2147483878,2147483879,15630812,2147483880,2147483881,15729119,2147483882,2147483883,15827426,2147483884,2147483885,15958501,2147483886,2147483887,2147483888,16155113,2147483889,16122347,2147483890,2147483891,2147483892,16482799,16351728,16318961,2147483893,2147483894,16417268,2147483895,2147483896,2147483897,16613880,16581113,2147483898,2147483899,16679420,2147483900,2147483901,2147483902,2147483903,2147483904,
};

pub const HuffmanTree = struct {
    data :u32,
    const Self = @This();
    //static constexpr std::uint32_t mask_zero = 0x00007fff;
    const mask_zero = 0x00007fff;
    //static constexpr std::uint32_t mask_one = 0x3fff8000;
    const mask_one = 0x3fff8000;
    //static constexpr std::uint32_t flag_value = 0x80000000;
    const flag_value = 0x80000000;
    //static constexpr std::uint32_t mask_shift = 15;
    const mask_shift = 15;
    pub fn one(self :Self) u16 {
        return @intCast((self.data & mask_one) >> mask_shift);
    }
    pub fn zero(self :Self) u16 {
        return @intCast(self.data & mask_zero);
    }
    fn is_not_set(self :Self) bool {
        return self.data == 0;
    }
    fn set_zero(self :Self, z :u16) Self {
        return Self{ .data = (self.data & mask_one) | z };
    }
    fn set_one(self :Self, o :u16) void {
        self.data = (self.data & mask_zero) | (o << mask_shift);
    }
    fn set_value(self :Self, v :u32) !void {
        self.data = v | flag_value;  
    }
    pub fn has_value(self :Self) bool {
        return self.data & flag_value != 0;
    }
    pub fn get_value(self :Self) u32 {
        return self.data & 0x7fffffff;
    }
};

pub fn getRoot() HuffmanTree {
    return HuffmanTree{ .data = raw_table[0] };
}

pub const HuffmanError = error {
    OutOfRange,
};

pub fn get_next(tree :HuffmanTree, bit :u1) !HuffmanTree {
    if (tree.has_value()) {
        return HuffmanError.OutOfRange;
    }
    var n :u32 = 0;
    if (bit == 0) {
        n = tree.zero();
    } else {
        n = tree.one();
    }
    if ( (n == 0) or (n >= raw_table.len)) {
        return HuffmanError.OutOfRange;
    } 
    return HuffmanTree{ .data = raw_table[n] };
}

pub const BitWriter = std.io.BitWriter(.big, std.io.AnyWriter);
pub const BitReader = std.io.BitReader(.big, std.io.AnyReader);

pub const Code = struct {
    literal :u16,
    bits :u5,
    code :u32,

    pub fn write(self :Code,w :*BitWriter) anyerror!void{
        //auto b = std::uint64_t(1) << (bits - 1);
        //for (auto i = 0; i < bits; i++) {
        //    out.push_back(code & b ? t : f);
        //    if (b == 1) {
        //        break;
        //    }
        //    b >>= 1;
        //}
        //return true;
        var b :u32 = @as(u32,1) << (self.bits - 1);
        var i :u5 = 0;
        while (i < self.bits) {
            if (self.code & b != 0) {
                try w.writeBits(@as(u1,1),1);
            } else {
                try w.writeBits(@as(u1,0),1);
            }
            if (b == 1) {
                break;
            }
            b >>= 1;
            i += 1;
        }
    }
};

pub const codes = [_]Code{
Code{.code = 8184, .bits = 13, .literal =0},
Code{.code = 8388568, .bits = 23, .literal =1},
Code{.code = 268435426, .bits = 28, .literal =2},
Code{.code = 268435427, .bits = 28, .literal =3},
Code{.code = 268435428, .bits = 28, .literal =4},
Code{.code = 268435429, .bits = 28, .literal =5},
Code{.code = 268435430, .bits = 28, .literal =6},
Code{.code = 268435431, .bits = 28, .literal =7},
Code{.code = 268435432, .bits = 28, .literal =8},
Code{.code = 16777194, .bits = 24, .literal =9},
Code{.code = 1073741820, .bits = 30, .literal =10},
Code{.code = 268435433, .bits = 28, .literal =11},
Code{.code = 268435434, .bits = 28, .literal =12},
Code{.code = 1073741821, .bits = 30, .literal =13},
Code{.code = 268435435, .bits = 28, .literal =14},
Code{.code = 268435436, .bits = 28, .literal =15},
Code{.code = 268435437, .bits = 28, .literal =16},
Code{.code = 268435438, .bits = 28, .literal =17},
Code{.code = 268435439, .bits = 28, .literal =18},
Code{.code = 268435440, .bits = 28, .literal =19},
Code{.code = 268435441, .bits = 28, .literal =20},
Code{.code = 268435442, .bits = 28, .literal =21},
Code{.code = 1073741822, .bits = 30, .literal =22},
Code{.code = 268435443, .bits = 28, .literal =23},
Code{.code = 268435444, .bits = 28, .literal =24},
Code{.code = 268435445, .bits = 28, .literal =25},
Code{.code = 268435446, .bits = 28, .literal =26},
Code{.code = 268435447, .bits = 28, .literal =27},
Code{.code = 268435448, .bits = 28, .literal =28},
Code{.code = 268435449, .bits = 28, .literal =29},
Code{.code = 268435450, .bits = 28, .literal =30},
Code{.code = 268435451, .bits = 28, .literal =31},
Code{.code = 20, .bits = 6, .literal =32},
Code{.code = 1016, .bits = 10, .literal =33},
Code{.code = 1017, .bits = 10, .literal =34},
Code{.code = 4090, .bits = 12, .literal =35},
Code{.code = 8185, .bits = 13, .literal =36},
Code{.code = 21, .bits = 6, .literal =37},
Code{.code = 248, .bits = 8, .literal =38},
Code{.code = 2042, .bits = 11, .literal =39},
Code{.code = 1018, .bits = 10, .literal =40},
Code{.code = 1019, .bits = 10, .literal =41},
Code{.code = 249, .bits = 8, .literal =42},
Code{.code = 2043, .bits = 11, .literal =43},
Code{.code = 250, .bits = 8, .literal =44},
Code{.code = 22, .bits = 6, .literal =45},
Code{.code = 23, .bits = 6, .literal =46},
Code{.code = 24, .bits = 6, .literal =47},
Code{.code = 0, .bits = 5, .literal =48},
Code{.code = 1, .bits = 5, .literal =49},
Code{.code = 2, .bits = 5, .literal =50},
Code{.code = 25, .bits = 6, .literal =51},
Code{.code = 26, .bits = 6, .literal =52},
Code{.code = 27, .bits = 6, .literal =53},
Code{.code = 28, .bits = 6, .literal =54},
Code{.code = 29, .bits = 6, .literal =55},
Code{.code = 30, .bits = 6, .literal =56},
Code{.code = 31, .bits = 6, .literal =57},
Code{.code = 92, .bits = 7, .literal =58},
Code{.code = 251, .bits = 8, .literal =59},
Code{.code = 32764, .bits = 15, .literal =60},
Code{.code = 32, .bits = 6, .literal =61},
Code{.code = 4091, .bits = 12, .literal =62},
Code{.code = 1020, .bits = 10, .literal =63},
Code{.code = 8186, .bits = 13, .literal =64},
Code{.code = 33, .bits = 6, .literal =65},
Code{.code = 93, .bits = 7, .literal =66},
Code{.code = 94, .bits = 7, .literal =67},
Code{.code = 95, .bits = 7, .literal =68},
Code{.code = 96, .bits = 7, .literal =69},
Code{.code = 97, .bits = 7, .literal =70},
Code{.code = 98, .bits = 7, .literal =71},
Code{.code = 99, .bits = 7, .literal =72},
Code{.code = 100, .bits = 7, .literal =73},
Code{.code = 101, .bits = 7, .literal =74},
Code{.code = 102, .bits = 7, .literal =75},
Code{.code = 103, .bits = 7, .literal =76},
Code{.code = 104, .bits = 7, .literal =77},
Code{.code = 105, .bits = 7, .literal =78},
Code{.code = 106, .bits = 7, .literal =79},
Code{.code = 107, .bits = 7, .literal =80},
Code{.code = 108, .bits = 7, .literal =81},
Code{.code = 109, .bits = 7, .literal =82},
Code{.code = 110, .bits = 7, .literal =83},
Code{.code = 111, .bits = 7, .literal =84},
Code{.code = 112, .bits = 7, .literal =85},
Code{.code = 113, .bits = 7, .literal =86},
Code{.code = 114, .bits = 7, .literal =87},
Code{.code = 252, .bits = 8, .literal =88},
Code{.code = 115, .bits = 7, .literal =89},
Code{.code = 253, .bits = 8, .literal =90},
Code{.code = 8187, .bits = 13, .literal =91},
Code{.code = 524272, .bits = 19, .literal =92},
Code{.code = 8188, .bits = 13, .literal =93},
Code{.code = 16380, .bits = 14, .literal =94},
Code{.code = 34, .bits = 6, .literal =95},
Code{.code = 32765, .bits = 15, .literal =96},
Code{.code = 3, .bits = 5, .literal =97},
Code{.code = 35, .bits = 6, .literal =98},
Code{.code = 4, .bits = 5, .literal =99},
Code{.code = 36, .bits = 6, .literal =100},
Code{.code = 5, .bits = 5, .literal =101},
Code{.code = 37, .bits = 6, .literal =102},
Code{.code = 38, .bits = 6, .literal =103},
Code{.code = 39, .bits = 6, .literal =104},
Code{.code = 6, .bits = 5, .literal =105},
Code{.code = 116, .bits = 7, .literal =106},
Code{.code = 117, .bits = 7, .literal =107},
Code{.code = 40, .bits = 6, .literal =108},
Code{.code = 41, .bits = 6, .literal =109},
Code{.code = 42, .bits = 6, .literal =110},
Code{.code = 7, .bits = 5, .literal =111},
Code{.code = 43, .bits = 6, .literal =112},
Code{.code = 118, .bits = 7, .literal =113},
Code{.code = 44, .bits = 6, .literal =114},
Code{.code = 8, .bits = 5, .literal =115},
Code{.code = 9, .bits = 5, .literal =116},
Code{.code = 45, .bits = 6, .literal =117},
Code{.code = 119, .bits = 7, .literal =118},
Code{.code = 120, .bits = 7, .literal =119},
Code{.code = 121, .bits = 7, .literal =120},
Code{.code = 122, .bits = 7, .literal =121},
Code{.code = 123, .bits = 7, .literal =122},
Code{.code = 32766, .bits = 15, .literal =123},
Code{.code = 2044, .bits = 11, .literal =124},
Code{.code = 16381, .bits = 14, .literal =125},
Code{.code = 8189, .bits = 13, .literal =126},
Code{.code = 268435452, .bits = 28, .literal =127},
Code{.code = 1048550, .bits = 20, .literal =128},
Code{.code = 4194258, .bits = 22, .literal =129},
Code{.code = 1048551, .bits = 20, .literal =130},
Code{.code = 1048552, .bits = 20, .literal =131},
Code{.code = 4194259, .bits = 22, .literal =132},
Code{.code = 4194260, .bits = 22, .literal =133},
Code{.code = 4194261, .bits = 22, .literal =134},
Code{.code = 8388569, .bits = 23, .literal =135},
Code{.code = 4194262, .bits = 22, .literal =136},
Code{.code = 8388570, .bits = 23, .literal =137},
Code{.code = 8388571, .bits = 23, .literal =138},
Code{.code = 8388572, .bits = 23, .literal =139},
Code{.code = 8388573, .bits = 23, .literal =140},
Code{.code = 8388574, .bits = 23, .literal =141},
Code{.code = 16777195, .bits = 24, .literal =142},
Code{.code = 8388575, .bits = 23, .literal =143},
Code{.code = 16777196, .bits = 24, .literal =144},
Code{.code = 16777197, .bits = 24, .literal =145},
Code{.code = 4194263, .bits = 22, .literal =146},
Code{.code = 8388576, .bits = 23, .literal =147},
Code{.code = 16777198, .bits = 24, .literal =148},
Code{.code = 8388577, .bits = 23, .literal =149},
Code{.code = 8388578, .bits = 23, .literal =150},
Code{.code = 8388579, .bits = 23, .literal =151},
Code{.code = 8388580, .bits = 23, .literal =152},
Code{.code = 2097116, .bits = 21, .literal =153},
Code{.code = 4194264, .bits = 22, .literal =154},
Code{.code = 8388581, .bits = 23, .literal =155},
Code{.code = 4194265, .bits = 22, .literal =156},
Code{.code = 8388582, .bits = 23, .literal =157},
Code{.code = 8388583, .bits = 23, .literal =158},
Code{.code = 16777199, .bits = 24, .literal =159},
Code{.code = 4194266, .bits = 22, .literal =160},
Code{.code = 2097117, .bits = 21, .literal =161},
Code{.code = 1048553, .bits = 20, .literal =162},
Code{.code = 4194267, .bits = 22, .literal =163},
Code{.code = 4194268, .bits = 22, .literal =164},
Code{.code = 8388584, .bits = 23, .literal =165},
Code{.code = 8388585, .bits = 23, .literal =166},
Code{.code = 2097118, .bits = 21, .literal =167},
Code{.code = 8388586, .bits = 23, .literal =168},
Code{.code = 4194269, .bits = 22, .literal =169},
Code{.code = 4194270, .bits = 22, .literal =170},
Code{.code = 16777200, .bits = 24, .literal =171},
Code{.code = 2097119, .bits = 21, .literal =172},
Code{.code = 4194271, .bits = 22, .literal =173},
Code{.code = 8388587, .bits = 23, .literal =174},
Code{.code = 8388588, .bits = 23, .literal =175},
Code{.code = 2097120, .bits = 21, .literal =176},
Code{.code = 2097121, .bits = 21, .literal =177},
Code{.code = 4194272, .bits = 22, .literal =178},
Code{.code = 2097122, .bits = 21, .literal =179},
Code{.code = 8388589, .bits = 23, .literal =180},
Code{.code = 4194273, .bits = 22, .literal =181},
Code{.code = 8388590, .bits = 23, .literal =182},
Code{.code = 8388591, .bits = 23, .literal =183},
Code{.code = 1048554, .bits = 20, .literal =184},
Code{.code = 4194274, .bits = 22, .literal =185},
Code{.code = 4194275, .bits = 22, .literal =186},
Code{.code = 4194276, .bits = 22, .literal =187},
Code{.code = 8388592, .bits = 23, .literal =188},
Code{.code = 4194277, .bits = 22, .literal =189},
Code{.code = 4194278, .bits = 22, .literal =190},
Code{.code = 8388593, .bits = 23, .literal =191},
Code{.code = 67108832, .bits = 26, .literal =192},
Code{.code = 67108833, .bits = 26, .literal =193},
Code{.code = 1048555, .bits = 20, .literal =194},
Code{.code = 524273, .bits = 19, .literal =195},
Code{.code = 4194279, .bits = 22, .literal =196},
Code{.code = 8388594, .bits = 23, .literal =197},
Code{.code = 4194280, .bits = 22, .literal =198},
Code{.code = 33554412, .bits = 25, .literal =199},
Code{.code = 67108834, .bits = 26, .literal =200},
Code{.code = 67108835, .bits = 26, .literal =201},
Code{.code = 67108836, .bits = 26, .literal =202},
Code{.code = 134217694, .bits = 27, .literal =203},
Code{.code = 134217695, .bits = 27, .literal =204},
Code{.code = 67108837, .bits = 26, .literal =205},
Code{.code = 16777201, .bits = 24, .literal =206},
Code{.code = 33554413, .bits = 25, .literal =207},
Code{.code = 524274, .bits = 19, .literal =208},
Code{.code = 2097123, .bits = 21, .literal =209},
Code{.code = 67108838, .bits = 26, .literal =210},
Code{.code = 134217696, .bits = 27, .literal =211},
Code{.code = 134217697, .bits = 27, .literal =212},
Code{.code = 67108839, .bits = 26, .literal =213},
Code{.code = 134217698, .bits = 27, .literal =214},
Code{.code = 16777202, .bits = 24, .literal =215},
Code{.code = 2097124, .bits = 21, .literal =216},
Code{.code = 2097125, .bits = 21, .literal =217},
Code{.code = 67108840, .bits = 26, .literal =218},
Code{.code = 67108841, .bits = 26, .literal =219},
Code{.code = 268435453, .bits = 28, .literal =220},
Code{.code = 134217699, .bits = 27, .literal =221},
Code{.code = 134217700, .bits = 27, .literal =222},
Code{.code = 134217701, .bits = 27, .literal =223},
Code{.code = 1048556, .bits = 20, .literal =224},
Code{.code = 16777203, .bits = 24, .literal =225},
Code{.code = 1048557, .bits = 20, .literal =226},
Code{.code = 2097126, .bits = 21, .literal =227},
Code{.code = 4194281, .bits = 22, .literal =228},
Code{.code = 2097127, .bits = 21, .literal =229},
Code{.code = 2097128, .bits = 21, .literal =230},
Code{.code = 8388595, .bits = 23, .literal =231},
Code{.code = 4194282, .bits = 22, .literal =232},
Code{.code = 4194283, .bits = 22, .literal =233},
Code{.code = 33554414, .bits = 25, .literal =234},
Code{.code = 33554415, .bits = 25, .literal =235},
Code{.code = 16777204, .bits = 24, .literal =236},
Code{.code = 16777205, .bits = 24, .literal =237},
Code{.code = 67108842, .bits = 26, .literal =238},
Code{.code = 8388596, .bits = 23, .literal =239},
Code{.code = 67108843, .bits = 26, .literal =240},
Code{.code = 134217702, .bits = 27, .literal =241},
Code{.code = 67108844, .bits = 26, .literal =242},
Code{.code = 67108845, .bits = 26, .literal =243},
Code{.code = 134217703, .bits = 27, .literal =244},
Code{.code = 134217704, .bits = 27, .literal =245},
Code{.code = 134217705, .bits = 27, .literal =246},
Code{.code = 134217706, .bits = 27, .literal =247},
Code{.code = 134217707, .bits = 27, .literal =248},
Code{.code = 268435454, .bits = 28, .literal =249},
Code{.code = 134217708, .bits = 27, .literal =250},
Code{.code = 134217709, .bits = 27, .literal =251},
Code{.code = 134217710, .bits = 27, .literal =252},
Code{.code = 134217711, .bits = 27, .literal =253},
Code{.code = 134217712, .bits = 27, .literal =254},
Code{.code = 67108846, .bits = 26, .literal =255},
Code{.code = 1073741823, .bits = 30, .literal =256},


};