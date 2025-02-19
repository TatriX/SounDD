// Version: 0.5.0

#module_parameters(SUPPORTED_FORMATS := Supported_Formats.WAV | .FLAC | .QOA, OUTPUT_SAMPLE_RATE: u32 = 44100) {
    Supported_Formats :: enum_flags {
        WAV;
        FLAC;
        QOA;
    }
}

#import "Basic";
#import "Math";
#import "File";
#import "String";
#import "Thread";

#if SUPPORTED_FORMATS & .WAV #load "wav.jai";
#if SUPPORTED_FORMATS & .FLAC #load "flac.jai";
#if SUPPORTED_FORMATS & .QOA #load "qoa.jai";

Audio_Format :: enum {
    WAV;
    FLAC;
    QOA;
}

Sound_Data :: struct {
    format: Audio_Format;

    is_stereo: bool;
    channel_count: u8;

    sample_count: u32;
    sample_rate: u32;
    samples_per_frame: float64;
    time_length: float64;
    rate_scale: float64;

    owned_source: string;
    samples: *s16;
}

Sound :: struct {
    volume: float32 = 1;
    speed: float32 = 1;
    time_position: float64;

    flags: enum_flags u8 {
        IS_PLAYING;

        SHOULD_REPEAT;
        DONT_DESTROY_AFTER_FINISH;
    };

    data: Sound_Data;
}

audio_master_volume: float32 = 1;

sound_data_load_from_file :: (path: string) -> Sound_Data {
    contents, success := read_entire_file(path);
    assert(success, "Failed to read file");

    splits := split(path, ".");
    extension := splits[splits.count-1];

    format: Audio_Format;
    if extension == {
        case "wav"; format = .WAV;
        case "flac"; format = .FLAC;
        case "qoa"; format = .QOA;
        case; assert(false, "Unsupported extension");
    }

    data := sound_data_load_from_string(contents, format);
    data.owned_source = contents;

    return data;
}

sound_data_load_from_string :: (str: string, format: Audio_Format) -> Sound_Data {
    data: Sound_Data;
    data.format = format;

    if format == .WAV {
        #if SUPPORTED_FORMATS & .WAV data = wav_decode_string(str);
        else assert(false, "WAV support is not enabled");
    } else if format == .FLAC {
        #if SUPPORTED_FORMATS & .FLAC data = flac_decode_string(str);
        else assert(false, "FLAC support is not enabled");
    } else if format == .QOA {
        #if SUPPORTED_FORMATS & .QOA data = qoa_decode_string(str);
        else assert(false, "QOA support is not enabled");
    } else assert(false, "Unsupported format");

    data.is_stereo = data.channel_count == 2;
    assert(data.channel_count <= 2, "Only mono and stereo are supported");

    data.time_length = cast(float64)data.sample_count / data.sample_rate / data.channel_count;
    data.rate_scale = cast(float64)data.sample_rate / OUTPUT_SAMPLE_RATE;
    data.samples_per_frame = data.time_length / data.sample_count;

    return data;
}

sound_data_free :: (data: Sound_Data) {
    if data.owned_source.data != null free(data.owned_source);

    if data.format == {
        // case .WAV; Data points to the original string, so it just got freed above
        case .FLAC; #if SUPPORTED_FORMATS & .FLAC flac_free_data(data);
        case .QOA; #if SUPPORTED_FORMATS & .QOA qoa_free_data(data);
    }
}

create :: (data: Sound_Data) -> *Sound {
    sound := New(Sound);
    sound.data = data;

    return sound;
}

destroy :: (sound: *Sound) {
    stop(sound);
    free(sound);
}

play :: (using sound: *Sound) {
    if flags & .IS_PLAYING return;
    flags |= .IS_PLAYING;

    lock(*main_mutex);
    array_add(*sounds_that_are_playing, sound);
    unlock(*main_mutex);
}

stop :: (using sound: *Sound) {
    if ~flags & .IS_PLAYING return;
    flags &= ~.IS_PLAYING;

    lock(*main_mutex);
    removed_amount := array_unordered_remove_by_value(*sounds_that_are_playing, sound, true);
    unlock(*main_mutex);

    assert(removed_amount == 1);

    time_position = 0;
}

logger_proc :: (tag: *u8, log_level: u32, log_item_id: u32, message_or_null: *u8, line_nr: u32, filename_or_null: *u8, user_data: *void) -> void #c_call {
    new_context: Context;
    push_context new_context {
        log("%: % % at (%:%)", tag, log_item_id, message_or_null, filename_or_null, line_nr);
    }
}

audio_init :: () {
    init(*main_mutex);

    // @Note: If anything randomly breaks, I will blame multithreading
    desc := SAudio_Desc.{
        sample_rate = xx OUTPUT_SAMPLE_RATE,
        num_channels = 2,
        stream_cb = saudio_stream_callback,
        saudio_allocator = .{
            alloc_fn = saudio_alloc,
            free_fn = saudio_free
        },
        logger = .{ func = logger_proc },
    };
    saudio_setup(*desc);
    assert(saudio_isvalid(), "Backed initialization failed");
}

audio_update :: () {
    for sounds_that_are_playing {
        using it;

        if time_position >= data.time_length {
            // The sound thread will repeat this for us
            if flags & .SHOULD_REPEAT continue;

            stop(it);
            if ~flags & .DONT_DESTROY_AFTER_FINISH destroy(it);
        }
    }
}

#scope_file

#if OS == .WINDOWS {
    sokol :: #library,no_dll "win/sokol";
    ole :: #system_library "ole32";
} else #if OS == .LINUX {
    sokol :: #library,no_dll "linux/sokol";
    alsa :: #system_library "libasound";
}

sounds_that_are_playing: [..]*Sound;
main_mutex: Mutex;

SAudio_Allocator :: struct {
    alloc_fn: (size: u64, user_data: *void) -> *void #c_call;
    free_fn: (ptr: *void, user_data: *void) -> void #c_call;
    user_data: *void;
}

SAudio_Logger :: struct {
    func: (tag: *u8, log_level: u32, log_item_id: u32, message_or_null: *u8, line_nr: u32, filename_or_null: *u8, user_data: *void) ->void #c_call;
    user_data: *void;
}

SAudio_Desc :: struct {
    sample_rate: s32;
    num_channels: s32;
    buffer_frames: s32;
    packet_frames: s32;
    num_packets: s32;
    stream_cb: (buffer: *float32, frame_count: s32, channel_count: s32) -> void #c_call;
    stream_userdata_cb: (buffer: *float32, frame_count: s32, channel_count: s32, user_data: *void) -> void #c_call;
    user_data: *void;
    saudio_allocator: SAudio_Allocator;
    logger: SAudio_Logger;
}

saudio_setup :: (desc: *SAudio_Desc) -> void #foreign sokol;
saudio_isvalid :: () -> bool #foreign sokol;
saudio_sample_rate :: () -> s32 #foreign sokol;

saudio_alloc :: (size: u64, user_data: *void) -> *void #c_call {
    new_context: Context;
    push_context new_context {
        return alloc(xx size);
    }
}

saudio_free :: (ptr: *void, user_data: *void) #c_call {
    new_context: Context;
    push_context new_context {
        free(ptr);
    }
}

saudio_stream_callback :: (buffer: *float32, frame_count: s32, channel_count: s32) #c_call {
    new_context: Context;
    push_context new_context {
        stream_callback(buffer, frame_count, channel_count);
    }
}

stream_callback :: (buffer: *float32, frame_count: s32, channel_count: s32) {
    assert(channel_count == 2);

    lock(*main_mutex);
    defer unlock(*main_mutex);

    for i: 0..frame_count-1 {
        left: float;
        right: float;

        for sounds_that_are_playing {
            using it;

            if time_position >= data.time_length {
                if flags & .SHOULD_REPEAT {
                    time_position = fmod_cycling(time_position, data.time_length);
                } else continue;
            }

            sample_counter := time_position / data.samples_per_frame;
            time_delta := data.samples_per_frame * data.rate_scale * speed;
            vol := volume * audio_master_volume;

            if data.is_stereo {
                begin_index := cast(u32)(sample_counter / 2) * 2;

                left_sample := data.samples[begin_index];
                right_sample := data.samples[begin_index + 1];

                left += (cast(float)left_sample / S16_MAX) * vol;
                right += (cast(float)right_sample / S16_MAX) * vol;

                time_position += time_delta * 2;
            } else {
                sample := data.samples[cast(u32)sample_counter];
                value := (cast(float)sample / S16_MAX) * vol;

                left += value;
                right += value;

                time_position += time_delta;
            }
        }

        buffer[i*2 + 0] = left;
        buffer[i*2 + 1] = right;
    }
}
