using static DeleteDuplicatedFilesConsole.Methods;
using static System.Console;

const string _red = "\x1b[31m";
const string _reset = "\x1b[0m";

Clear();
WriteLine($"{_red}Warning!\nAll Files Within same size will be deleted include raw images.{_reset}\n");
WriteLine("Insert Input Path For Deleting Duplicated Files Based On Size:");
string? inputPath = ReadLine();

if(string.IsNullOrWhiteSpace(inputPath))
    return;

WriteLine("\nSelect Search Option:\n(1) Include Subfolders\n(2) not Include Subfolers");
string? searchOptionVar = ReadLine();
bool searchOption;

try
{
    // determine whathever search option is
    if(string.IsNullOrEmpty(searchOptionVar))
        throw new NotImplementedException(nameof(searchOption));
    if(searchOptionVar.Equals("1", StringComparison.OrdinalIgnoreCase))
        searchOption = true;
    else if(searchOptionVar.Equals("2", StringComparison.OrdinalIgnoreCase))
        searchOption = false;
    else
        throw new IndexOutOfRangeException(nameof(searchOption));
}
catch(Exception ex)
{
    WriteLine(ex.Message);
    ReadKey();
    return;
}


Clear();
WriteLine($"Selected Path is: {inputPath}\n\nSubfolder Search is: {searchOption}\n\n");

if(!string.IsNullOrWhiteSpace(inputPath))
    DeleteFiles(inputPath, searchOption);

Write("\nPress any key to exit...");
ReadKey();