HttpClient client = new HttpClient();
string web = await client.GetStringAsync(@"https://starbeamrainbowlabs.com/blog/article.php?article=posts%2F346-Easy-Ansi-Escape-Sequences.html");

GC.Collect();

using var fs = new FileStream("./Web1.html", FileMode.OpenOrCreate, FileAccess.Write);
using var sw = new StreamWriter(fs);
sw.WriteLine(web);

Console.Write("Press any key to continue.");