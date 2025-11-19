using System.Globalization;
using static System.Console;
using static System.IO.Directory;
using static System.IO.Path;

try
{
    Clear();
    Write("Specify the directory where your files are located:\t");
    var sourceDirectory = ReadLine();

    Write("insert Destination Directory:\t");
    var targetDirectory = ReadLine();
    
    var directoriesExist = Directory.Exists(sourceDirectory) && Directory.Exists(targetDirectory);

    if (!directoriesExist && string.IsNullOrEmpty(targetDirectory) && string.IsNullOrEmpty(sourceDirectory))
        throw new Exception("Source directory or Target Directory doesn't exist.");

    if (targetDirectory != null && sourceDirectory != null)
    {
        var files = GetFiles(sourceDirectory,".",SearchOption.AllDirectories);
        var totalFiles = files.Length;

        var persianCalendar = new PersianCalendar();
    
        for (var i = 0; i < totalFiles; i++)
        {
            var filePath = files[i];

            var lastModifiedDate = File.GetLastWriteTime(filePath);

            var year = persianCalendar.GetYear(lastModifiedDate);
            var month = persianCalendar.GetMonth(lastModifiedDate);
            var monthName = GetPersianMonthName(month);

            var yearDirectory = Combine(targetDirectory, year.ToString());
            if (!Directory.Exists(yearDirectory))            
                CreateDirectory(yearDirectory);
                
            var monthDirectory = Combine(yearDirectory, monthName);
    
            if (!Directory.Exists(monthDirectory))
                CreateDirectory(monthDirectory);

            var fileName = GetFileName(filePath);
            var destinationPath = Combine(monthDirectory, fileName);
    
            try
            {
                File.Move(filePath, destinationPath);
            }
            catch (IOException ex)
            {
                WriteLine($"Error moving file {fileName}: {ex.Message}");
            }

            var remainingFiles = totalFiles - (i + 1);
            WriteLine($"Remaining files: {remainingFiles}/{totalFiles}");
        }
        WriteLine("Files organized successfully.");    
    }
}
catch (Exception ex)
{
    Clear();
    WriteLine($"An Error occured during Progress:\n{ex.Message}");
}
finally
{
    WriteLine("Press any key to exit.");
    ReadKey();
}

return; //Separate Local Functions with return; statement for readability  

string GetPersianMonthName(int month)
{
    string[] persianMonths =
    [
        "Farvardin",
        "Ordibehesht",
        "Khordad",
        "Tir",
        "Mordad",
        "Shahrivar",
        "Mehr",
        "Aban",
        "Azar",
        "Dey",
        "Bahman",
        "Esfand"
    ];
    return persianMonths[month - 1]; // Month is 1-based (Indexes Starts With 0)
}
