#!/bin/bash
# Play 2 s of silence through PipeWire's default sink (the WSLg tunnel) and show that
# WSLg's PulseAudio server receives a stream from it. Silence: nothing audible.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
PW="unix:$XDG_RUNTIME_DIR/pulse/native"
head -c 384000 /dev/zero | PULSE_SERVER=$PW pacat --raw --format=s16le --rate=48000 --channels=2 &
sleep 1
echo "pipewire sink: $(PULSE_SERVER=$PW pactl list short sinks | grep wslg-sink | awk '{print $NF}')"
echo "WSLg sink-inputs:"; PULSE_SERVER=unix:/mnt/wslg/PulseServer pactl list sink-inputs | grep -E "Sink Input|application.name|media.name|Sink:" 
wait
