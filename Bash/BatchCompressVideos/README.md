A good `README.md` is essential for documenting a script, especially one with flexible, optional arguments.

Here is a complete `README.md` content block for this robust, flag-based script (`Batch_Compress_Videos.sh`), ready for shipping.

markdown
# 🎬 Video Compression Script (Batch_Compress_Videos.sh)

A simple, yet powerful Bash script utilizing FFmpeg to batch-compress all common video file types (`.mp4`, `.mov`, `.mkv`, `.hevc`, etc.) within a specified directory. The script offers flexible control over the output location and compression bitrate using command-line flags.

---

## 🛠️ Prerequisites

This script requires **FFmpeg** to be installed on your system.

### Installation (Ubuntu/Debian)

```bash
sudo apt update
sudo apt install ffmpeg
````

-----

## 🚀 How to Use

### 1\. Make the Script Executable

If you haven't already, make the script executable:

```bash
chmod +x Batch_Compress_Videos.sh
```

### 2\. Basic Command Syntax

The script is executed using the `-i` flag for the mandatory input directory, and optional flags for the output directory (`-o`) and bitrate (`-b`).

```bash
./Batch_Compress_Videos.sh -i <input_directory> [-o <output_directory>] [-b <target_bitrate>]
```

-----

## ⚙️ Options

| Flag | Description | Mandatory | Default Value |
| :--- | :--- | :--- | :--- |
| `-i` | **Input directory** containing the video files to be compressed. | Yes | N/A |
| `-o` | **Output directory** where the compressed videos will be saved. | No | `<input_directory>/CompressedVideos` |
| `-b` | **Target video bitrate** for compression (e.g., `5000k`, `8M`). | No | `5000k` (5 Megabits per second) |

**Note on Bitrate:** FFmpeg accepts standard units. Use `k` for kilobits (`kbps`) and `M` for megabits (`Mbps`). Lower bitrates result in smaller files and higher compression (lower quality).

-----

## 💡 Examples

### Example 1: Use Defaults

Compresses all videos in the input directory. Output is saved to a subdirectory named `CompressedVideos` inside the input directory, using the default bitrate of **`5000k`**.

```bash
./Batch_Compress_Videos.sh -i /home/mikaeeil/Pictures/1404/Aban
```

### Example 2: Set Custom Bitrate (Skip Output)

Compresses videos using a higher quality bitrate of **`8M`**. The output directory remains the default (`<input_directory>/CompressedVideos`).

```bash
./Batch_Compress_Videos.sh -i /home/mikaeeil/Pictures/1404/Aban -b 8M
```

### Example 3: Set Custom Output and Bitrate

Compresses videos using a very high bitrate of **`15M`** and saves them to a separate, specified output folder.

```bash
./Batch_Compress_Videos.sh -i /path/to/source/videos -o /path/to/final/compressed -b 15M
```

-----

## 🗂️ Supported Video Types

The script automatically searches for files with the following common extensions:

  * `.mp4`
  * `.mov`
  * `.avi`
  * `.mkv`
  * `.webm`
  * `.flv`
  * `.hevc`
  * `.h265`

All output files are standardized to the **`.mp4`** container format for maximum compatibility.