namespace ZamndxLauncher;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();

        try
        {
            Application.Run(new MainForm());
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                exception.Message,
                "ZAMN DX",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
