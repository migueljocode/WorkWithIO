namespace DeleteDuplicatedFilesConsole;

public class Methods
{
    public static void DeleteFiles(string folderPath, bool subFolderCheck)
    {
        const string _green = "\x1b[32m";
        const string _red = "\x1b[31m";
        const string _reset = "\x1b[0m";
        int deletedFiles = 0;
        long deletedSize = 0;
        // folderPath += Path.DirectorySeparatorChar;
        List<FileInfo> files = new List<FileInfo>();

        try
        {
            if(subFolderCheck)
                files = Directory.GetFiles(folderPath, "*.*", SearchOption.AllDirectories).Select(file => new FileInfo(file)).OrderBy(x => x.LastWriteTime).ThenBy(x => x.CreationTime).ThenBy(x => x.LastAccessTime).ToList();
            else
                files = Directory.GetFiles(folderPath, "*.*", SearchOption.TopDirectoryOnly).Select(file => new FileInfo(file)).OrderBy(x => x.LastWriteTime).ThenBy(x => x.CreationTime).ThenBy(x => x.LastAccessTime).ToList();
                // Directory.GetFiles(folderPath, "*", SearchOption.TopDirectoryOnly).Select(file => new FileInfo(file)).OrderBy(x => (x.Name).Length).ThenBy(x => x.Name).ToList();
        }
        catch(Exception ex)
        {
            Console.WriteLine($"{_red}an error occured during getting files from source:\n{ex.Message}{_reset}");
            return;
        }

        var groupedFiles = files.GroupBy(file => file.Length);  
            
        try
        {

            // Iterate through each group of files with the same size
            foreach (var group in groupedFiles)
            {
                if (group.Count() > 1) // Only consider groups with more than one file
                {
                    // Keep the first file and delete the rest
                    var filesToDelete = group.Skip(1); // Skip the first file

                    foreach (var file in filesToDelete)
                    {
                        try
                        {
                            File.Delete(file.FullName);
                            Console.WriteLine($"Deleted: {Path.GetFileName(file.FullName)}");
                            deletedFiles++;
                            deletedSize += file.Length;
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"Error deleting file {file.FullName}: {ex.Message}");
                            return;
                        }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"\n\nAn error occurred:{ex.Message}");
            return;
        }
        Console.WriteLine('\n');
        Console.WriteLine("Process is Done!\n");
        // ConsoleColor originalColor = Console.ForegroundColor;
        // Console.ForegroundColor = ConsoleColor.Red;
        // Console.WriteLine($"Deleted Files Count: {deletedFiles}");
        Console.WriteLine($"{_red}Deleted Files Count: {deletedFiles}{_reset}");    
        // Console.ForegroundColor = originalColor;
        // Console.ForegroundColor = ConsoleColor.Green; 
        // Console.WriteLine($"Obtained Storage: {deletedSize / (1024 * 1024)} MB");
        Console.WriteLine($"{_green}Obtained Storage: {deletedSize / (1024 * 1024)} MB{_reset}");
        // Console.ForegroundColor = originalColor;
    }
}