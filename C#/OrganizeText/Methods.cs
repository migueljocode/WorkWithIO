global using System.IO;
global using static System.Console;
global using static Methods;
using System.Text;
using Microsoft.VisualBasic;

public class Methods
{
    public static void GetStrings(string inputPath, string outputPath)
    {
        StringBuilder stringBuilder = new StringBuilder();


        using (StreamReader sr = new StreamReader(inputPath))
            stringBuilder.Append(sr.ReadToEnd());


        int count = default;
        
        using (StreamWriter sw = new StreamWriter(outputPath))
            foreach (string line in stringBuilder.ToString().Split())
                sw.WriteLine($"{++count}. {line}");
            
    }
}