namespace PNG_To_TXT_Tesseract_MultiTrhead;

internal class StaticMethods
{
    internal static Bitmap ConvertToGrayscale(Bitmap original)
    {
        if (!IsWindowsVersionAtLeast(6, 1))
            throw new PlatformNotSupportedException("at least windows (7) is excepted for running this app!");

        Bitmap grayscale = new(original.Width, original.Height);
        using (Graphics g = Graphics.FromImage(grayscale))
        {
            ColorMatrix colorMatrix = new ColorMatrix(new float[][]
            {
        new float[] {0.299f, 0.299f, 0.299f, 0, 0},
        new float[] {0.587f, 0.587f, 0.587f, 0, 0},
        new float[] {0.114f, 0.114f, 0.114f, 0, 0},
        new float[] {0, 0, 0, 1, 0},
        new float[] {0, 0, 0, 0, 1}
            });

            using (ImageAttributes attributes = new ImageAttributes())
            {
                attributes.SetColorMatrix(colorMatrix);
                g.DrawImage(original, new Rectangle(0, 0, original.Width, original.Height), 0, 0, original.Width, original.Height, GraphicsUnit.Pixel, attributes);
            }
        }
        return grayscale;
    }
    internal static readonly object combinedWriterLock = new object();
}
