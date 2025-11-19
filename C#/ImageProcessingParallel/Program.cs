using System.Collections.Concurrent;
using System.Diagnostics;
using ImageMagick;
using static System.IO.Directory;
using static System.Console;
using static System.IO.Path;
using static System.Convert;
using static System.Threading.Tasks.Parallel;

const string _redForeground = "\u001b[31m";
const string _greenForeground = "\u001b[32m";
const string _brightBlueForeground = "\u001b[94m";
const string _defaultForeground = "\u001b[0m";
const string _brightMagentaForeground = "\u001b[95m";
ulong _inputDirectorySizeInByte = default;
float _inputDirectorySizeInMB = default;
ulong _outputDirectorySizeInByte = default;
float _outputDirectorySizeInMB = default;
string? inputFolder;
string? outputFolder;
uint quality = default;
ConcurrentBag<string> failedFiles = new ConcurrentBag<string>();
string[]? files;
Stopwatch sw;
ParallelOptions options = new ParallelOptions { MaxDegreeOfParallelism = Environment.ProcessorCount };
int _cpuCores = Environment.ProcessorCount;
int _filesCount = default;
int _completedFiles = 1;
string[] _supportedFormats = [ ".jpg", ".jpeg", ".png", ".cr2", ".dng", ".heic", ".heif" ];

Clear();

try
{
    WriteLine($"Proseccor Count: {_cpuCores}, this is the maximum number of concurrent processes and very depend on your CPU!\n");

    // Get Input Directory
    WriteLine("insert images folder:");
    inputFolder = ReadLine();
    if (!Directory.Exists(inputFolder))
        throw new DirectoryNotFoundException(inputFolder);
    
    // Get Total Size Before Compression
    foreach (var item in GetFiles(path: inputFolder, searchPattern: "*.*", searchOption: SearchOption.AllDirectories))
        _inputDirectorySizeInByte += ToUInt32(new FileInfo(item).Length);
    _inputDirectorySizeInMB = _inputDirectorySizeInByte / (float)(1000 * 1000);

    // Get Output Directory
    WriteLine("insert destination folder:");
    outputFolder = ReadLine();
    if (string.IsNullOrEmpty(outputFolder))
        throw new ArgumentNullException(outputFolder);
    else if (!Directory.Exists(outputFolder))
        CreateDirectory(outputFolder);
    
    // Set Image Quality
    WriteLine("insert image Quality only (0 - 100) ,Suggested Value: > 75");
    quality = ToUInt16(ReadLine());
    if (quality < 0 || quality > 100)
        throw new IndexOutOfRangeException("Quality Value is Out Of Range!");


    Clear();
    WriteLine($"Source Folder:     \t{GetFileNameWithoutExtension(inputFolder)}");
    WriteLine($"Destination Folder:\t{GetFileNameWithoutExtension(outputFolder)}");
    WriteLine($"Quality:          \t{quality}%\n");


    
    files = GetFiles(inputFolder, "*.*")
            .Where(file => _supportedFormats.Contains(GetExtension(file).ToLower()))
            .ToArray();
    
    _filesCount = files.Length;

    //start stopwatch for monitor speed
    sw = Stopwatch.StartNew();

    // Process files in parallel
    await ForEachAsync(files, options, DoWork);

    sw.Stop();


    // Get Total Size After Compression
    foreach(var item in GetFiles(path: outputFolder, searchPattern: "*.*", searchOption: SearchOption.AllDirectories))
        _outputDirectorySizeInByte += ToUInt32(new FileInfo(item).Length);
    _outputDirectorySizeInMB = _outputDirectorySizeInByte / (float)(1000 * 1000);

    WriteLine($"\nProcessing Completed!\n");
    WriteLine($"{_brightMagentaForeground}Elspaed Time:         \t{(sw.ElapsedMilliseconds / (float)1000).ToString("F1")}s{_defaultForeground}");
    WriteLine($"{_redForeground}Input Directory Size: \t{_inputDirectorySizeInMB.ToString("F2")} MB{_defaultForeground}");
    WriteLine($"{_greenForeground}Output Directory Size:\t{_outputDirectorySizeInMB.ToString("F2")} MB{_defaultForeground}");
    WriteLine($"{_brightBlueForeground}Difference:           \t{(_inputDirectorySizeInMB - _outputDirectorySizeInMB).ToString("F2")} MB{_defaultForeground}\n");

    if (!failedFiles.IsEmpty)
    {
        WriteLine($"{_redForeground}Failed Files:");
        foreach (var failed in failedFiles)
            WriteLine(failed);
        WriteLine($"{_defaultForeground}");
    }

}
catch (DirectoryNotFoundException dx)
{
    WriteLine($"Directory Not Found: {dx.Message}");
}
catch (ArgumentNullException ax)
{
    WriteLine($"Directory Should't be empty: {ax.Message}");
}
catch (Exception ex)
{
    WriteLine(ex.Message);
}
finally
{
    WriteLine("Press any key to exit.");
    ReadKey();
}

// separate functions with return statement.
return;

async Task<bool> CompressImageAsync(string file, string outputPath, uint quality)
{
    return await Task.Run(() =>
    {
        try
        {
            using (var image = new MagickImage(file))
            {
                image.Resize(3840, 2160); // Optional resizing  
                image.Quality = quality; // Compression quality  

                // Convert RAW formats to JPEG if applicable
                if (image.Format == MagickFormat.Cr2 || image.Format == MagickFormat.Dng || image.Format == MagickFormat.Heic || image.Format == MagickFormat.Heif)
                    image.Format = MagickFormat.Jpeg;

                image.Write(outputPath);
                WriteLine($"Processed ({_completedFiles}/{_filesCount}):\t{GetFileName(file)}");
                _completedFiles++;
                return true; // Success
            }
        }
        catch (Exception ex)
        {
            WriteLine($"Failed: {GetFileName(file)} - {ex.Message}");
            return false; // Failure
        }
    });
}

async ValueTask DoWork (string file, CancellationToken ct)
{
    string fileName = GetFileNameWithoutExtension(file) + ".jpg";
    string outputFile = Combine(outputFolder, fileName);

    bool success = await CompressImageAsync(file, outputFile, quality);
    if (!success)
        failedFiles.Add(file); // Capture failed files
}