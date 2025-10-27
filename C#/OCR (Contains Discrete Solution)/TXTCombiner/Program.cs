string? inputPath = string.Empty;
string? outputPath = string.Empty;
string[] inputFiles;
StringBuilder output = new StringBuilder();
Func<string, int> GetNumberInsideString = (string input) =>
{
    string key = new string(input.Where(char.IsDigit).ToArray());
    return string.IsNullOrEmpty(key) ? 0 : int.Parse(key);
};

try
{
	WriteLine("insert input directory path containing txt files to combine: ");
	inputPath = ReadLine();

	WriteLine("insert ouput directory path: ");
	outputPath = ReadLine();

	if (string.IsNullOrEmpty(inputPath) || inputPath is null)
		throw new ArgumentException("input path is Invalid!");
	if (string.IsNullOrEmpty(outputPath) || outputPath is null)
		throw new ArgumentException("output path is Invalid!");
	if (!Directory.Exists(inputPath))
		throw new ArgumentException("input path is not found!");
	if (!Directory.Exists(outputPath))
		CreateDirectory(outputPath);

	inputFiles = GetFiles(inputPath, "Page_*.txt");
	inputFiles = inputFiles.OrderBy(x => GetNumberInsideString(x)).ToArray();

	WriteLine($"founded files count: {inputFiles.Count()}");

	foreach (string file in inputFiles)
	{
		WriteLine($"\toutput writed to file : {GetFileName(file)}");
		output.AppendLine($"\n\n\n=== output from file: {GetFileName(file)} ===");
		output.AppendLine(ReadAllText(file));
	}

	WriteAllText(Combine(outputPath, "combined_text.txt"), output.ToString().Trim());
	WriteLine("Done.");
}
catch (Exception ex)
{
	WriteLine($"\x1b[1;31mError:\x1b[0m\t{ex.Message}");
}
finally
{
	Write("\nPress Any Key To Continue...");
    Read();
}