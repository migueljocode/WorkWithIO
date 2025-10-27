global using static System.Console;
global using static System.IO.File;
global using static System.IO.Path;

// first commit completed!

string inputDir;
string directory;
string fileName;
string noExtension;
string edited;
string logged;
string editedWithExtension;
string outputPath;
string logPath;
string inputText;
Dictionary<string, string> strings;
string[] words;
SortedSet<string> wordsSet;
Dictionary<string, int> WordAndRepeats;



GetFilePath(out inputDir);
FillVariables(out directory, ref inputDir, out fileName, out noExtension, out edited, out logged, out editedWithExtension, out outputPath, out logPath, out strings);

Clear();
ShowDirectoriesToUse(ref strings);


if (!Continue())
    return;

Clear();

inputText = ReadAllText(inputDir);
FillArray(out words, ref inputText);
FillSet(ref words, out wordsSet);
WriteLine("Words Count Before Removing Duplications: {0}", words.Length);
WriteLine("Words Count After Removing Duplications: {0}", wordsSet.Count);
WriteWords(ref wordsSet, ref outputPath);
FillDictionary(out WordAndRepeats, ref wordsSet, ref words);
Log(ref WordAndRepeats, ref logPath);
ReadKey();


return;


static void GetFilePath(out string inputDirectory)
{
    Write("insert input Path: ");

    inputDirectory = ReadLine();
    if (inputDirectory is null || string.IsNullOrEmpty(inputDirectory))
        throw new ArgumentNullException(nameof(inputDirectory));

}
static void FillVariables(out string directoryNamex, ref string inputDirectory, out string outputFileName, out string fileNameNoExtension, out string editedFileName, out string loggedFileName, out string editedWithExtensionFileName, out string outputPathName, out string logPathName, out Dictionary<string, string> stringsDictionary)
{
    directoryNamex = GetDirectoryName(inputDirectory);
    if (directoryNamex is null)
        throw new ArgumentNullException(nameof(inputDirectory));
    else if (string.IsNullOrEmpty(directoryNamex))
        throw new InvalidDataException("the Directory For that path is empty!");

    outputFileName = GetFileName(inputDirectory);
    fileNameNoExtension = GetFileNameWithoutExtension(inputDirectory);
    editedFileName = string.Format("{0}_{1}", fileNameNoExtension, "Edited");
    loggedFileName = string.Concat(fileNameNoExtension, '_', "Log.txt");
    editedWithExtensionFileName = string.Concat(editedFileName, ".txt");
    outputPathName = Combine(directoryNamex, editedWithExtensionFileName);
    logPathName = Combine(directoryNamex, loggedFileName);

    stringsDictionary = new()
    {
        { nameof(inputDirectory), inputDirectory },
        { nameof(directoryNamex), directoryNamex },
        { nameof(outputFileName), outputFileName },
        { nameof(fileNameNoExtension), fileNameNoExtension },
        { nameof(editedFileName), editedFileName },
        { nameof(outputPathName), outputPathName }
    };
}
static void ShowDirectoriesToUse(ref Dictionary<string, string> dict)
{
    foreach (var item in dict)
        WriteLine($"[{item.Key}]\t[{item.Value}]");
}
static bool Continue()
{
    Write("Is These Currect? (Y,N): ");

    ConsoleKeyInfo input = ReadKey();
    char inputChar = input.KeyChar;

    if (char.Equals(inputChar, 'Y') || char.Equals(inputChar, 'y'))
        return true;
    else
        return false;
}
static void FillArray(out string[] array, ref string input)
{
    array = input.Split('\n');
}
static void FillSet(ref string[] array, out SortedSet<string> set)
{
    set = new SortedSet<string>();
    foreach (string word in array)
        set.Add(word);
}
static void WriteWords(ref SortedSet<string> set, ref string output)
{
    string wordsToOutput = string.Empty;
    foreach (string word in set)
        wordsToOutput += $"{word}\n";

    WriteAllText(output, wordsToOutput);
    WriteLine("Operation Completed.");

}
static void FillDictionary(out Dictionary<string, int> dict, ref SortedSet<string> set, ref string[] array)
{
    dict = new Dictionary<string, int>();
    foreach (var i in set)
    {
        int itemCount = default;

        foreach (var j in array)
            if (string.Equals(i, j))
                itemCount++;

        dict.Add(i, itemCount);
    }

}
static void Log(ref Dictionary<string, int> dict, ref string ouputPath)
{
    string log = string.Empty;
    foreach (var item in dict)
    {
        string key = item.Key.Trim();
        string value = item.Value.ToString();
        log += $"[{key}] repeated [{value}] time\n\n";
    }
    WriteAllText(ouputPath, log);
    Write("Log Saved.");
}