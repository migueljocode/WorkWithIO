# WorkWithIO

A collection of practical input/output (I/O) utilities and examples implemented in Bash and C#. Each project demonstrates common I/O tasks — batch media processing, file-system utilities, text/HTML extraction, parallel image processing, OCR demos, and more.

This README provides an indexed, per-project reference so you can quickly find, build, and run each project.

---

## Table of contents

- [Repository layout](#repository-layout)  
- [How to get the code](#how-to-get-the-code)  
- Projects
  - [Bash — BatchCompressVideos](#bash---batchcompressvideos)
  - [C# — DeleteDuplicatedFilesConsole](#c---deleteduplicatedfilesconsole)
  - [C# — ExtractContacts](#c---extractcontacts)
  - [C# — ExtractHTML](#c---extracthtml)
  - [C# — FormatChanger](#c---formatchanger)
  - [C# — ImageProcessingParallel](#c---imageprocessingparallel)
  - [C# — MyRemoveDuplicatedWords](#c---myremoveduplicatedwords)
  - [C# — OCR (Contains Discrete Solution)](#c---ocr-contains-discrete-solution)
  - [C# — OrganizeText](#c---organizetext)
  - [C# — SortFilesAccordingToLastWriteTimeInPersianCalenderShamsi_dotnet10](#c---sortfilesaccordingtolastwritetimeinpersiancalendarshamsi_dotnet10)
- [General prerequisites](#general-prerequisites)
- [Contributing](#contributing)
- [License & author](#license--author)
- [Support / Contact](#support--contact)

---

## Repository layout

Top-level items:
- [.gitignore](https://github.com/migueljocode/WorkWithIO/blob/master/.gitignore)  
- [Bash/](https://github.com/migueljocode/WorkWithIO/tree/master/Bash) — Bash utilities and scripts  
  - [Bash/BatchCompressVideos](https://github.com/migueljocode/WorkWithIO/tree/master/Bash/BatchCompressVideos)
    - [Batch_Compress_Videos.sh](https://github.com/migueljocode/WorkWithIO/blob/master/Bash/BatchCompressVideos/Batch_Compress_Videos.sh)
    - [Bash/BatchCompressVideos/README.md](https://github.com/migueljocode/WorkWithIO/blob/master/Bash/BatchCompressVideos/README.md)
- [C#/](https://github.com/migueljocode/WorkWithIO/tree/master/C%23) — C# sample projects and utilities  
  - [C#/DeleteDuplicatedFilesConsole](https://github.com/migueljocode/WorkWithIO/tree/master/C%23/DeleteDuplicatedFilesConsole)  
  - [C#/ExtractContacts](https://github.com/migueljocode/WorkWithIO/tree/master/C%23/ExtractContacts)  
  - [C#/ExtractHTML](https://github.com/migueljocode/WorkWithIO/tree/master/C%23/ExtractHTML)  
  - [C#/FormatChanger](https://github.com/migueljocode/WorkWithIO/tree/master/C%23/FormatChanger)  
  - [C#/ImageProcessingParallel](https://github.com/migueljocode/WorkWithIO/tree/master/C%23/ImageProcessingParallel)  
  - [C#/MyRemoveDuplicatedWords](https://github.com/migueljocode/WorkWithIO/tree/master/C%23/MyRemoveDuplicatedWords)  
  - [C#/OCR (Contains Discrete Solution)](https://github.com/migueljocode/WorkWithIO/tree/master/C%23/OCR%20(Contains%20Discrete%20Solution))  
  - [C#/OrganizeText](https://github.com/migueljocode/WorkWithIO/tree/master/C%23/OrganizeText)  
  - [C#/SortFilesAccordingToLastWriteTimeInPersianCalenderShamsi_dotnet10](https://github.com/migueljocode/WorkWithIO/tree/master/C%23/SortFilesAccordingToLastWriteTimeInPersianCalenderShamsi_dotnet10)  
  - [C#/WorkWithIO.slnx](https://github.com/migueljocode/WorkWithIO/blob/master/C%23/WorkWithIO.slnx) — solution aggregate file

---

## How to get the code

Clone the repository:
```bash
git clone https://github.com/migueljocode/WorkWithIO.git
cd WorkWithIO
```

---

## Projects

Each project below has a short description, location, key files, prerequisites and quick run/build instructions.

### Bash — BatchCompressVideos
- Path: `Bash/BatchCompressVideos`  
- Files:
  - [Batch_Compress_Videos.sh](https://github.com/migueljocode/WorkWithIO/blob/master/Bash/BatchCompressVideos/Batch_Compress_Videos.sh) — main script  
  - [README.md](https://github.com/migueljocode/WorkWithIO/blob/master/Bash/BatchCompressVideos/README.md) — detailed usage
- Purpose: Batch-compress common video file types in a folder using FFmpeg and save standardized `.mp4` outputs.
- Key features:
  - Supports: `.mp4`, `.mov`, `.avi`, `.mkv`, `.webm`, `.flv`, `.hevc`, `.h265`
  - Outputs to `<input>/CompressedVideos` by default
  - Accepts a target bitrate flag
- Prerequisite: FFmpeg installed on the machine.
- Quick usage:
  ```bash
  chmod +x Bash/BatchCompressVideos/Batch_Compress_Videos.sh
  ./Bash/BatchCompressVideos/Batch_Compress_Videos.sh -i /path/to/source -o /path/to/out -b 5000k
  ```
- Notes: Test with a small set before bulk-processing. See the per-project README for more examples and recommended FFmpeg options.

---

### C# — DeleteDuplicatedFilesConsole
- Path: `C#/DeleteDuplicatedFilesConsole`  
- Purpose (from name): Console utility to find and delete duplicate files (likely by hashing or size comparison).
- Key files: open the directory to inspect the project file and `Program.cs`.
- How to run:
  - From repo root:
    ```bash
    dotnet build C#/DeleteDuplicatedFilesConsole
    dotnet run --project C#/DeleteDuplicatedFilesConsole
    ```
  - Check command-line arguments in the project's `Program.cs` (if present) for usage details.
- Notes: Always test with a safe sample directory or run in "dry-run" mode if available.

---

### C# — ExtractContacts
- Path: `C#/ExtractContacts`  
- Purpose: Extract contact information (phone numbers, emails, etc.) from files or directories.
- How to run:
  ```bash
  dotnet build C#/ExtractContacts
  dotnet run --project C#/ExtractContacts -- <input-files-or-dir>
  ```
- Notes: Inspect source for supported input formats and output location.

---

### C# — ExtractHTML
- Path: `C#/ExtractHTML`  
- Purpose: Tools to extract content from HTML files (text, links, metadata) or to generate simplified outputs from HTML sources.
- How to run:
  ```bash
  dotnet build C#/ExtractHTML
  dotnet run --project C#/ExtractHTML -- <html-file-or-dir>
  ```
- Notes: Check dependencies in the project file (HTML parsers, AngleSharp, etc.) and add them if required.

---

### C# — FormatChanger
- Path: `C#/FormatChanger`  
- Purpose: Convert or change file formats (e.g., rename extensions, convert text encodings, reformat content).
- How to run:
  ```bash
  dotnet build C#/FormatChanger
  dotnet run --project C#/FormatChanger -- <options>
  ```
- Notes: Read the project code to discover supported formats and command-line options.

---

### C# — ImageProcessingParallel
- Path: `C#/ImageProcessingParallel`  
- Purpose: Parallelized image processing utilities (resize, convert, apply filters) using multiple threads/tasks to speed up processing large collections.
- How to run:
  ```bash
  dotnet build C#/ImageProcessingParallel
  dotnet run --project C#/ImageProcessingParallel -- <input-dir> <output-dir> [options]
  ```
- Notes: Look for parallelization control (max degree of parallelism) inside the project.

---

### C# — MyRemoveDuplicatedWords
- Path: `C#/MyRemoveDuplicatedWords`  
- Purpose: Utility to remove duplicated words from text documents (useful for cleaning OCR output, merged text, etc.).
- How to run:
  ```bash
  dotnet build C#/MyRemoveDuplicatedWords
  dotnet run --project C#/MyRemoveDuplicatedWords -- <input-file> <output-file>
  ```

---

### C# — OCR (Contains Discrete Solution)
- Path: `C#/OCR (Contains Discrete Solution)`  
- Purpose: An OCR demo/solution showing how to perform optical character recognition on images/documents. The name suggests it contains a complete, discrete approach.
- Prerequisites: likely requires an OCR library (Tesseract or other). Inspect project references.
- How to run:
  ```bash
  dotnet build "C#/OCR (Contains Discrete Solution)"
  dotnet run --project "C#/OCR (Contains Discrete Solution)" -- <image-or-dir>
  ```

---

### C# — OrganizeText
- Path: `C#/OrganizeText`  
- Purpose: Utilities to clean, sort, group or otherwise organize textual data (e.g., lists, logs, contact dumps).
- How to run:
  ```bash
  dotnet build C#/OrganizeText
  dotnet run --project C#/OrganizeText -- <input> <options>
  ```

---

### C# — SortFilesAccordingToLastWriteTimeInPersianCalenderShamsi_dotnet10
- Path: `C#/SortFilesAccordingToLastWriteTimeInPersianCalenderShamsi_dotnet10`  
- Purpose: Sort files by last-write time using the Persian (Shamsi) calendar representation. The suffix suggests targeting .NET 10 or a naming convention including the target framework.
- How to run:
  ```bash
  dotnet build "C#/SortFilesAccordingToLastWriteTimeInPersianCalenderShamsi_dotnet10"
  dotnet run --project "C#/SortFilesAccordingToLastWriteTimeInPersianCalenderShamsi_dotnet10" -- <dir>
  ```
- Notes: If culture-specific formatting is used, ensure required globalization packages are referenced.

---

## Using the solution file

The C# projects are grouped under a solution file:
- [C#/WorkWithIO.slnx](https://github.com/migueljocode/WorkWithIO/blob/master/C%23/WorkWithIO.slnx)

Open the solution in Visual Studio or Rider, or work with `dotnet` CLI:
```bash
dotnet restore C#/WorkWithIO.slnx
dotnet build C#/WorkWithIO.slnx
```

To run a specific project:
```bash
dotnet run --project C#/<ProjectFolderName>
```

---

## General prerequisites

- Bash projects:
  - Unix-like environment (Linux, macOS, or WSL on Windows)
  - FFmpeg for `Batch_Compress_Videos.sh`
- C# projects:
  - .NET SDK installed. Check each project's csproj for target framework (if unknown, install a recent LTS SDK such as .NET 8 or .NET 10 preview if the name implies .NET 10).
  - Additional NuGet packages may be required per project (see each project's csproj or source).

---

## Contributing

Contributions are welcome. Suggested process:
1. Fork the repository.
2. Create a branch: `git checkout -b feature/your-feature`
3. Implement changes; run and test locally.
4. Open a pull request describing the change. Include screenshots or logs if relevant.

If you add a new project, add a short README to the project folder and link it from this top-level README.

---

## License & author

- Author: [migueljocode](https://github.com/migueljocode)  
- License: No license file present in the repository root. If you are the repo owner and want a license, add a `LICENSE` file. Until a license is added, use is governed by the repository owner's terms.

---

## Support / Contact

Open an issue in the repository for bugs, feature requests, or questions:
https://github.com/migueljocode/WorkWithIO/issues

---

Notes and next steps
- Many C# folders may contain `Program.cs` and a project file — inspect each folder for specific command-line options and per-project READMEs.  
- If you want, I can:
  - generate or expand per-project README.md files (I can draft README files for each C# project based on the code), or
  - create a LICENSE file and contributing templates, or
  - produce usage examples / CLI argument docs for each C# program (requires me to read each `Program.cs`).
Please tell me which next step you prefer.
