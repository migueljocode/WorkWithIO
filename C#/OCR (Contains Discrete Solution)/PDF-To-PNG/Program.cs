string? inputFilePathTest = null;
string? outputDirectoryPathTest = null;
string inputFilePath = string.Empty;
string outputDirectoryPath = string.Empty;
int outputWidth = default;
int outputHeight = default;
float scaleFactor = default;
string outputFileName;
//Stream[] outputStreams;
string outputFilePath;


try
{
    WriteLine("insert input file location: ");
    inputFilePathTest = ReadLine();

    WriteLine("insert output file directory: ");
    outputDirectoryPathTest = ReadLine();

    WriteLine("insert output image Width (for example insert 1920): ");
    outputWidth = ToInt32(ReadLine());

    WriteLine("insert output image Height (for example insert 1080): ");
    outputHeight = ToInt32(ReadLine());

    WriteLine("insert Scale Factor (for example insert 1): ");
    scaleFactor = ToSingle(ReadLine());

    if (IsNullOrWhiteSpace(inputFilePathTest) || IsNullOrWhiteSpace(outputDirectoryPathTest) || IsNullOrEmpty(inputFilePathTest) || IsNullOrEmpty(outputDirectoryPathTest))
        throw new ArgumentNullException("inserted path is unvalid!");
    else
    {
        inputFilePath = inputFilePathTest.Trim();
        outputDirectoryPath = outputDirectoryPathTest.Trim();
    }

    if (!File.Exists(inputFilePath))
        throw new IOException("specified file is not found!");

    // Ensure output directory exists
    if (!Directory.Exists(outputDirectoryPath))
        CreateDirectory(outputDirectoryPath);

    // Optional: Register Syncfusion license if available
    // Syncfusion.Licensing.SyncfusionLicenseProvider.RegisterLicense("YOUR_LICENSE_KEY");

    // Load the PDF document to get page count
    using (FileStream inputStream = new FileStream(inputFilePath, FileMode.Open, FileAccess.Read))
    {
        using (PdfToImageConverter imageConverter = new PdfToImageConverter())
        {
            imageConverter.Load(inputStream);

            // Verify page count
            if (imageConverter.PageCount == 0)
                throw new IOException("No pages found in the PDF!");

            Clear();

            WriteLine($"Found {imageConverter.PageCount} pages in the PDF.");

            // Set up parallel options to limit concurrency to number of CPU cores
            var parallelOptions = new ParallelOptions
            {
                MaxDegreeOfParallelism = Environment.ProcessorCount
            };

            // Process pages in parallel
            Parallel.For(0, imageConverter.PageCount, parallelOptions, i =>
            {
                try
                {
                    // Create a new PdfToImageConverter instance for each thread
                    using (var threadConverter = new PdfToImageConverter())
                    {
                        // Reopen the input stream for each thread
                        using (FileStream threadInputStream = new(inputFilePath, FileMode.Open, FileAccess.Read))
                        {
                            threadConverter.Load(threadInputStream);
                            threadConverter.ScaleFactor = scaleFactor;

                            // Convert a single page to an image stream
                            Stream[] singlePageStream = threadConverter.Convert(i, i, new(width: outputWidth, height: outputHeight), true, false, true);

                            if (singlePageStream[0] == null || singlePageStream[0].Length == 0)
                            {
                                lock (consoleLock)
                                {
                                    WriteLine($"Warning: Page {i + 1} produced an empty stream.");
                                }
                                return;
                            }

                            // Reset stream position
                            singlePageStream[0].Position = 0;

                            // Save to file
                            outputFileName = string.Format("Page_{0:D5}.png", i + 1);
                            outputFilePath = Combine(outputDirectoryPath, outputFileName);
                            using (FileStream outputFileStream = new(outputFilePath, FileMode.Create, FileAccess.Write))
                            {
                                singlePageStream[0].CopyTo(outputFileStream);
                                outputFileStream.Flush();
                                lock (consoleLock)
                                {
                                    WriteLine($"Saved {outputFilePath} ({singlePageStream[0].Length} bytes)");
                                }
                            }

                            singlePageStream[0].Dispose();
                        }
                    }
                }
                catch (Exception ex)
                {
                    lock (consoleLock)
                    {
                        WriteLine($"Error processing page {i + 1}: {ex.Message}");
                    }
                }
            });
        }
    }

    WriteLine("PDF pages converted successfully.");
}
catch (Exception ex)
{
    WriteLine($"Error: {ex.Message}");
    WriteLine($"Stack Trace: {ex.StackTrace}");
}
Read();