global using static System.Console;

var directory = @"/home/mikaeeil/Pictures/Moon";
var files = Directory.GetFiles(directory);
foreach(var file in files)
    if(Path.GetFileName(file).EndsWith("CR2"))
    {
        var newDirName = Path.Combine(directory, "Reformatted");
        if(!Directory.Exists(newDirName))
            Directory.CreateDirectory(newDirName);
        var newFile = Path.Combine(newDirName, Path.GetFileNameWithoutExtension(file));   
        File.Copy(file, string.Format($"{newFile}.dng"));
    }
WriteLine("Process Completed");