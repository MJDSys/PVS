
# This class manages the GUI's console for PVS

import wx
import codecs
import util
from promptprocessor import isPrompt
from constants import *
from wx.lib.pubsub import pub
from ui.plugin import PluginPanel
import pvscomm

log = util.getLogger(__name__)

class ConsolePlugin(PluginPanel):
    """This class represents and manages the console.
    This console shows the PVS output, and the user can enter a line of input"""
    
    def __init__(self, parent, definition):
        PluginPanel.__init__(self, parent, definition)
        self.prompt = EMPTY_STRING
        self.history = []
        self.pvsout = wx.TextCtrl(self, wx.ID_ANY, EMPTY_STRING, style=wx.TE_MULTILINE | wx.TE_READONLY)
        self.pvsin = wx.TextCtrl(self, wx.ID_ANY, EMPTY_STRING, style=wx.TE_PROCESS_ENTER)
        
        self.mainPanel = wx.Panel(self, wx.ID_ANY)
        #TODO: Try to add a little border to pvsin and pvsout
        mainPanelSizer = wx.BoxSizer(wx.VERTICAL)
        mainPanelSizer.Add(self.pvsout, 1, wx.EXPAND | wx.LEFT, 5)
        mainPanelSizer.Add(self.pvsin, 0, wx.EXPAND | wx.LEFT, 5)
        self.mainPanel.SetSizer(mainPanelSizer)
        
        consoleSizer = wx.BoxSizer(wx.HORIZONTAL)
        consoleSizer.Add(self.mainPanel, 1, wx.EXPAND | wx.LEFT, 5)
        self.SetSizer(consoleSizer)        

        
        self.Bind(wx.EVT_TEXT_ENTER, self.onPVSInTextEntered, self.pvsin)
        self.Bind(wx.EVT_TEXT, self.onPVSInText, self.pvsin)
        pub.subscribe(self.clearIn, PUB_CONSOLECLEARIN)
        pub.subscribe(self.setInEditable, PUB_CONSOLEINEDITABLE)
        pub.subscribe(self.initializeConsole, PUB_CONSOLEINITIALIZE)
        pub.subscribe(self.writeLine, PUB_CONSOLEWRITELINE)
        pub.subscribe(self.writePrompt, PUB_CONSOLEWRITEPROMPT)
        pub.subscribe(self.pvsModeUpdated, PUB_UPDATEPVSMODE)


    def pvsModeUpdated(self, pvsMode=PVS_MODE_OFF):
        if pvsMode == PVS_MODE_OFF:
            log.debug("Disabling pvsin")
            self.setInEditable(False)
        else:
            self.setInEditable(True)

    def clearOut(self):
        """Clears the PVS output text in the console"""
        self.pvsout.Clear()
        log.debug("Clearing pvsout")
        
    def clearIn(self):
        """Clears the PVS prompt box in the console"""
        self.pvsin.Clear()
        log.debug("Clearing pvsin")
        
    def setInEditable(self, value):
        self.pvsin.SetEditable(value)
        
    def initializeConsole(self):
        """Initializes PVS In and Out"""
        self.pvsout.Clear()
        self.pvsin.Clear()
        self.prompt = EMPTY_STRING
        self.history = []
        self.pvsModeUpdated(PVS_MODE_OFF)
        
    def appendLineToOut(self, line):
        log.debug("Appending '%s' to pvsout", line)
        self.pvsout.AppendText(line + NEWLINE)
        
    def appendTextToOut(self, text):
        log.debug("Appending '%s' to pvsout", text)
        self.pvsout.AppendText(text)      
        
    def appendTextToIn(self, text):
        log.debug("Appending '%s' to pvsin", text)
        self.pvsin.AppendText(text)
        
    def writeTextToIn(self, text):
        log.debug("Writing '%s' to pvsin", text)
        self.pvsin.write(text)
        
    def writeLine(self, line):
        self.appendLineToOut(line)
        
    def writePrompt(self, prompt):
        self.clearIn()
        self.writeTextToIn(prompt)
        self.prompt = prompt
                
    def onPVSInTextEntered(self, event):
        """This method is called whenever the user types something in the prompt and Enters."""
        log.info("Event handler `onPVSInTextEntered' not implemented")
        whole = event.GetString()
        pl = len(self.prompt)
        command = whole[pl:]
        log.info("Command is %s", command)
        self.appendLineToOut(whole)
        self.clearIn()
        self.history.append(command)
        pvscomm.PVSCommandManager().sendRawCommand(command + NEWLINE)
        #event.Skip()
    
    def onPVSInText(self, event):
        """This method is called whenever PVS sends some text to the Editor"""
        st = event.GetString()
        log.info("Received: %s", st)
        if not st.startswith(self.prompt):
            self.clearIn()
            self.writeTextToIn(self.prompt)
        #event.Skip()
        

        
        