string combinedOutputFile = string.Empty;

Clear();

try
{
    if (!IsWindows())
        throw new PlatformNotSupportedException("running platform must be Windows for this app!");
    else if (!IsWindowsVersionAtLeast(6, 1))
        throw new PlatformNotSupportedException("at least Windows (7) is excepted for running this app!");

    // Define input and output directories
    string? inputDir; // Directory containing PNG files
    string? outputDir; // Directory to save text files
    var currentDirectory = Directory.GetCurrentDirectory();
    var tessDatas = Path.Combine(currentDirectory, "tessdata");
    string tessdataPath = tessDatas; // Path to Tesseract language data

    WriteLine("insert images directory: ");
    inputDir = ReadLine();
    WriteLine("insert output directory: ");
    outputDir = ReadLine();

    if (inputDir is null || outputDir is null)
        throw new ArgumentNullException("specified path(s) is not in correct format!");

    combinedOutputFile = Combine(outputDir, "combined_output.txt"); // Combined text output file

    WriteLine("insert language number to scan:\n1.persian\n2.english");
    byte languageNumber = ToByte(ReadLine());
    string selectedLanguage = string.Empty;
    switch (languageNumber)
    {
        case 1:
            selectedLanguage = "fas";
            break;
        case 2:
            selectedLanguage = "eng";
            break;
    }

    // Ensure input directory exists
    if (!Directory.Exists(inputDir))
        throw new ArgumentException($"Input directory '{inputDir}' does not exist.");

    // Create output directory if it doesn't exist
    if (!Directory.Exists(outputDir))
        CreateDirectory(outputDir);

    // Ensure tessdata directory exists
    if (!Directory.Exists(tessdataPath) || !File.Exists(Combine(tessdataPath, "fas.traineddata")) || !File.Exists(Combine(tessdataPath, "eng.traineddata")))
        throw new Exception($"Error: Tesseract language data not found in '{tessdataPath}'. Please download 'fas.traineddata' for Persian or 'eng.traineddata' for english.");

    // Get all PNG files from the input directory
    string[] pngFiles = GetFiles(inputDir, "*.png");
    if (pngFiles.Length == 0)
        throw new IOException($"Error: No PNG files found in '{inputDir}'.");

    WriteLine($"Found {pngFiles.Length} PNG files for OCR processing.");

    // Initialize combined output stream with UTF-8 encoding for Persian text
    using (StreamWriter combinedWriter = new(combinedOutputFile, false, UTF8))
    {
        // Set up parallel options to limit concurrency to number of CPU cores
        var parallelOptions = new ParallelOptions
        {
            MaxDegreeOfParallelism = Environment.ProcessorCount
        };

        // Process PNG files in parallel
        Parallel.ForEach(pngFiles, parallelOptions, pngFile =>
        {
            if (!IsWindows())
                throw new PlatformNotSupportedException("running platform must be windows for this app!");
            else if (!IsWindowsVersionAtLeast(6, 1))
                throw new PlatformNotSupportedException("at least windows (7) is excepted for running this app!");

            try
            {
                // Each thread creates its own TesseractEngine instance for thread safety
                using (var engine = new TesseractEngine(tessdataPath, selectedLanguage, EngineMode.Default))
                {
                    // Preprocess image: convert to grayscale
                    using (Bitmap originalImage = new(pngFile))
                    {
                        using (Bitmap grayscaleImage = ConvertToGrayscale(originalImage))
                        {
                            // Save temporary preprocessed image
                            string tempImagePath = Combine(GetTempPath(), $"{NewGuid()}.png");
                            grayscaleImage.Save(tempImagePath, Png);

                            try
                            {
                                // Perform OCR on preprocessed image
                                using (var img = LoadFromFile(tempImagePath))
                                {
                                    using (var page = engine.Process(img))
                                    {
                                        string recognizedText = page.GetText();

                                        // Skip empty results
                                        if (string.IsNullOrWhiteSpace(recognizedText))
                                        {
                                            WriteLine($"Warning: No text recognized in '{GetFileName(pngFile)}'.");
                                            return;
                                        }

                                        // Save individual text file with UTF-8 encoding
                                        string outputTextFile = Combine(outputDir, $"{GetFileNameWithoutExtension(pngFile)}.txt");
                                        WriteAllText(outputTextFile, recognizedText, UTF8);
                                        WriteLine($"Saved text from '{GetFileName(pngFile)}' to '{outputTextFile}' ({recognizedText.Length} characters).");

                                        // Append to combined output file with thread-safe locking
                                        lock (combinedWriterLock)
                                        {
                                            combinedWriter.WriteLine($"=== Text from {GetFileName(pngFile)} ===");
                                            combinedWriter.WriteLine(recognizedText);
                                            combinedWriter.WriteLine();
                                        }
                                    }
                                }
                            }
                            finally
                            {
                                // Clean up temporary image
                                if (File.Exists(tempImagePath))
                                    File.Delete(tempImagePath);
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                WriteLine($"Error processing '{GetFileName(pngFile)}': {ex.Message}");
            }
        });
    }

    WriteLine($"All recognized text saved to '{combinedOutputFile}'.");
    WriteLine("OCR processing completed successfully.");
}
catch (Exception ex)
{
    WriteLine($"Fatal error: {ex.Message}");
    WriteLine($"Stack Trace: {ex.StackTrace}");
}

File.Delete(combinedOutputFile);
WriteLine("Press any key to exit...");
Read();