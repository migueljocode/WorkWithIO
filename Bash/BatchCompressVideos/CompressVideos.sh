#!/bin/bash

# Directory containing the videos
input_dir="/media/mikaeeil/ADATA HD720/Media/1404/Tir-(videos uncompresses)"
output_dir="/media/mikaeeil/ADATA HD720/Media/1404/Tir-(videos uncompresses)/compressed Videos"

# Create output directory if it doesn't exist
mkdir -p "$output_dir"

# Loop through all .mp4 files in the input directory
for video in "$input_dir"/*.MOV; do
    # Get the base name of the video file
    base_name=$(basename "$video" .mp4)
    
    # Output file path
    output_file="$output_dir/${base_name}_compressed.mp4"
    
    # FFmpeg command to compress the video
    ffmpeg -i "$video" -b:v 10000k "$output_file"
    
    echo "Compressed $video to $output_file"
done

echo "All videos have been compressed."
