#! /usr/bin/env bash

# --- Configuration ---
DEFAULT_BITRATE="5000k"
COMPRESSED_SUBDIR="CompressedVideos"
video_extensions=("mp4" "mov" "avi" "mkv" "webm" "flv" "hevc" "h265")
# --- End Configuration ---

# --- Argument Variables ---
input_dir=""          # Mandatory, must be set by -i
output_dir=""
target_bitrate="$DEFAULT_BITRATE"

# Function to display usage information
usage() {
    echo "Usage: $0 -i <input_directory> [-o <output_directory>] [-b <target_bitrate>]"
    echo " "
    echo "Options:"
    echo "  -i  Input directory (Mandatory)"
    echo "  -o  Output directory (Optional. Default: \$INPUT_DIR/$COMPRESSED_SUBDIR)"
    echo "  -b  Target video bitrate (Optional. Default: $DEFAULT_BITRATE)"
    echo " "
    echo "Example 1: $0 -i /path/to/videos"
    echo "Example 2 (Skip Output, Set Bitrate): $0 -i /path/to/videos -b 8M"
    echo "Example 3: $0 -i /path/to/videos -o /path/to/out -b 5000k"
    exit 1
}

# --- Parse Flags using getopts ---
# i, o, and b require an argument (indicated by the ':')
while getopts "i:o:b:" opt; do
    case "${opt}" in
        i)
            input_dir="${OPTARG}"
            ;;
        o)
            output_dir="${OPTARG}"
            ;;
        b)
            target_bitrate="${OPTARG}"
            ;;
        *)
            usage
            ;;
    esac
done

# --- Validate Mandatory Input ---
if [ -z "$input_dir" ]; then
    echo "Error: Input directory (-i) is mandatory."
    usage
fi

# --- Apply Default for Output Directory ---
if [ -z "$output_dir" ]; then
    output_dir="$input_dir/$COMPRESSED_SUBDIR"
fi

# Flag to track if any videos were found
videos_found=0

# Create output directory if it doesn't exist
mkdir -p "$output_dir"

# --- Script Start ---
echo "🎬 Starting video compression (Flag-Based)"
echo "---"
echo "Input Directory: **$input_dir**"
echo "Output Directory: **$output_dir**"
echo "Target Bitrate: **$target_bitrate**"
echo "---"

# Loop through extensions and videos (Core logic remains the same)
for ext in "${video_extensions[@]}"; do
    for video in "$input_dir"/*."$ext"; do
        
        if [ -f "$video" ]; then
            videos_found=1
            
            base_name_with_ext=$(basename "$video")
            base_name="${base_name_with_ext%.*}"
            
            output_file="$output_dir/${base_name}_compressed.mp4"
            
            echo "Processing: **$base_name_with_ext**"
            
            # FFmpeg command
            ffmpeg -i "$video" -c:v libx264 -b:v "$target_bitrate" "$output_file"
            
            if [ $? -eq 0 ]; then
                echo "✅ Compressed to **$target_bitrate** and saved as $output_file"
            else
                echo "❌ ERROR processing $base_name_with_ext"
            fi
            echo "---"
        fi
    done
done

if [ "$videos_found" -eq 0 ]; then
    echo "No supported video files found in $input_dir."
else
    echo "All supported videos have been processed."
fi
