using System.Diagnostics;

namespace StopYapping;

internal sealed class SettingsWindow : Form
{
    private readonly ComboBox microphones = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly NumericUpDown milliseconds = new() { Minimum = 60, Maximum = 500, Increment = 10, Width = 100 };

    public SettingsWindow(AudioEndpoint[] inputs, AudioEndpoint? selected, int delayMs, bool cableInstalled)
    {
        Text = "Stop Yapping settings";
        AutoScaleMode = AutoScaleMode.Dpi;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MinimizeBox = false;
        MaximizeBox = false;
        ClientSize = new Size(480, 290);

        var fields = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), RowCount = 8, ColumnCount = 1 };
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        fields.Controls.Add(Caption("Microphone for calls"));
        microphones.Items.AddRange(inputs);
        microphones.SelectedItem = selected;
        fields.Controls.Add(microphones);
        fields.Controls.Add(Caption("First-word protection (ms)"));
        milliseconds.Value = delayMs;
        fields.Controls.Add(milliseconds);
        fields.Controls.Add(Caption("Increase this if the start of your dictation slips through."));
        fields.Controls.Add(Caption(cableInstalled
            ? "In Discord → Voice & Video, choose CABLE Output as the microphone."
            : "Install VB-CABLE, then select CABLE Output in Discord."));
        if (!cableInstalled)
        {
            var link = new LinkLabel { Text = "Get VB-CABLE from the official website", AutoSize = true };
            link.LinkClicked += (_, _) => Process.Start(new ProcessStartInfo("https://vb-audio.com/Cable/") { UseShellExecute = true });
            fields.Controls.Add(link);
        }

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, AutoSize = true };
        var save = new Button { Text = "Save", DialogResult = DialogResult.OK, AutoSize = true, Enabled = Microphone is not null };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        microphones.SelectedIndexChanged += (_, _) => save.Enabled = Microphone is not null;
        buttons.Controls.Add(save);
        buttons.Controls.Add(cancel);
        fields.Controls.Add(buttons);
        AcceptButton = save;
        CancelButton = cancel;
        Controls.Add(fields);
    }

    public AudioEndpoint? Microphone => microphones.SelectedItem as AudioEndpoint;
    public int DelayMs => (int)milliseconds.Value;

    private static Label Caption(string value) => new()
    {
        Text = value, AutoSize = true, Margin = new Padding(3, 8, 3, 4)
    };
}
