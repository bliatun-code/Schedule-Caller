# Schedule Caller

Full-screen aerobatic practice widgets for FrSky ETHOS. Advance, repeat or restart the schedule with your assigned radio switches. Practise with full descriptions, switch to short name-only calls as you learn the sequence, or turn speech off. Choose English, Norwegian, or English names with Norwegian descriptions.

| Edition | Schedules |
| --- | --- |
| **IMAC** | IMAC 2027 Basic, Sportsman, Intermediate, Advanced and Unlimited, with Intermediate ALT, Advanced ALT and Unlimited ALT |
| **F3A** | A-27, P-27 and F-27, including their figure 10 alternatives |
| **Sportflyer** | F3A-Sport 2011 and Vingtreff |

**Version 1.0.4** uses far less Lua memory. The widget code is loaded only when a model uses Schedule Caller and is freed again when you change to a model that does not, also after you have used the widget menu. It keeps the reliable power-on and the lighter running next to the VoltDeck and GasDeck widgets from 1.0.2. Calls, audio, diagrams and settings are unchanged, and your settings carry over when you install 1.0.4 on top. [Release notes](https://github.com/bliatun-code/Schedule-Caller/releases/tag/v1.0.4)

[Installation packages](https://github.com/bliatun-code/Schedule-Caller/releases/latest) · [Illustrated setup guide](docs/Configuration.md) · [Norsk konfigurasjonsguide](docs/Konfigurasjon-norsk.md) · [Lua source](src/) · [Credits and rights](RIGHTS.md)

![Diagram view advancing through two manoeuvres in each of the IMAC, F3A and Sportflyer widgets](docs/images/diagram-preview.gif)

Tap the wind selector on the start screen to choose which diagrams the widget displays. Show the current and next manoeuvre names for a quick prompt, or hide both to give the drawing more room. The GIF shows the default view on the X20RS simulator.

<table>
<tr>
<td><img src="docs/images/readme-f3a-dark-diagram.png" alt="F3A F-27 diagram with both manoeuvre names visible" width="400"><br><b>Dark · Diagram</b><br>Current and next names visible.</td>
<td><img src="docs/images/briefing-example.png" alt="F3A A-27 briefing with a written description and the next figure beside it" width="400"><br><b>Light · Briefing</b><br>Written instructions with a side preview.</td>
</tr>
<tr>
<td><img src="docs/images/readme-imac-custom-deck.png" alt="IMAC Advanced deck with a teal background, figure number and next manoeuvre" width="400"><br><b>Custom · Deck</b><br>Your colours with a dedicated figure-number column.</td>
<td><img src="docs/images/readme-sportflyer-radio-diagram.png" alt="F3A-Sport 2011 Triangle Loop diagram with only the current name shown" width="400"><br><b>Radio theme · Diagram</b><br>Current name with room for the drawing.</td>
</tr>
</table>

Illustrations from IMAC (International Miniature Aerobatic Club). CIAM F3 Aerobatic drawings by Peter Uhlig. Sportflyer examples are based on the F3A-Sport 2011 schedule diagrams. [See the same figures in Light and Dark](docs/Configuration.md#light-and-dark).
