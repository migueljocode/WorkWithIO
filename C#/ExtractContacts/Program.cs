using System.Text;

string inputFile = Path.Combine(Directory.GetCurrentDirectory(), "RawFile");
string outputFile = Path.Combine(Directory.GetCurrentDirectory(), "Contacts.csv");

try
{
    SortContacts(inputFile, outputFile);
}
catch (Exception ex)
{
    WriteLine(ex.Message);
}

WriteLine($"Contacts Writed to: {Path.GetFileName(outputFile)}");

static void SortContacts(string inputFile, string outputFile)
{
    if (!File.Exists(outputFile))
        File.Create(outputFile);

    string[] lines = File.ReadAllLines(inputFile);

    StringBuilder stringBuilder = new StringBuilder();

    foreach(string line in lines)
    {
        string[] contact = line.Split(':');
        string contactName = contact[0].TrimStart().TrimEnd();
        string contactNumber = contact[1].TrimStart().TrimEnd();
        stringBuilder.AppendLine($"{contactName},{StandardizeNumber(contactNumber)}");
    }
    File.WriteAllText(outputFile, stringBuilder.ToString());
}

static string StandardizeNumber(string rawNumber)
{
    //think phone is: 0911 180 0973 or +98 911 178 0973 or +989111789973 or 09111780973 or not iranian number

    string digitOnly = new string(rawNumber.Where(char.IsDigit).ToArray());

    // phone now is: 0911180973 or 989111780973 **non digit characters removed**

    if (digitOnly.StartsWith("98")) /* so the actual number is: +989111780973 */
    {
        char simbol = '+';
        string firstPart = digitOnly.Substring(0, 2); /* 98 */
        string secondPart = digitOnly.Substring(2, 3); /* 911 */
        string thirdPart = digitOnly.Substring(5, 3); /* 178 */
        string lastPart = digitOnly.Substring(8); /* 0973 */
        return $"{simbol}{firstPart} {secondPart} {thirdPart} {lastPart}"; /* +98 911 178 0973 */
    }
    else if (digitOnly.StartsWith("09")) /* if the actual number is: 09111780973 */
    {
        char simbol = '+';
        string begining = "98";
        string firstPart = digitOnly.Substring(1, 3); /* 911 */
        string secondPart = digitOnly.Substring(4, 3); /* 178 */
        string lastPart = digitOnly.Substring(7); /* 0973 */
        return $"{simbol}{begining} {firstPart} {secondPart} {lastPart}"; /* +98 911 178 0973 */
    }
    else return rawNumber; /* not start with 09 or +98 so maybe not iranian number */
}