-------------------------------------------------------------------------------
-- File       : Sgmii88E1111LvdsUltraScale.vhd
-- Company    : SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
-- Description: Controller for the Marvell 88E1111 PHY 
-------------------------------------------------------------------------------
-- This file is part of 'SLAC Firmware Standard Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'SLAC Firmware Standard Library', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.AxiLitePkg.all;
use work.EthMacPkg.all;

entity Sgmii88E1111LvdsUltraScale is
   generic (
      TPD_G             : time                  := 1 ns;
      STABLE_CLK_FREQ_G : real                  := 156.25E+6;
      PHY_G             : natural range 0 to 31 := 7;
      AXIS_CONFIG_G     : AxiStreamConfigType   := AXI_STREAM_CONFIG_INIT_C);
   port (
      -- clock and reset
      extRst      : in    sl;
      stableClk   : in    sl;
      -- Local Configurations
      localMac    : in    slv(47 downto 0);  --  big-Endian configuration   
      -- Interface to Ethernet Media Access Controller (MAC)
      macClk      : in    sl;                -- Stable clock reference
      macRst      : in    sl;
      obMacMaster : out   AxiStreamMasterType;
      obMacSlave  : in    AxiStreamSlaveType;
      ibMacMaster : in    AxiStreamMasterType;
      ibMacSlave  : out   AxiStreamSlaveType;
      -- ETH external PHY Ports
      phyClkP     : in    sl;                -- 625.0 MHz
      phyClkN     : in    sl;
      phyMdc      : out   sl;
      phyMdio     : inout sl;
      phyRstN     : out   sl;                -- active low
      phyIrqN     : in    sl;                -- active low      
      -- LVDS SGMII Ports
      sgmiiRxP    : in    sl;
      sgmiiRxN    : in    sl;
      sgmiiTxP    : out   sl;
      sgmiiTxN    : out   sl);
end entity Sgmii88E1111LvdsUltraScale;

architecture mapping of Sgmii88E1111LvdsUltraScale is

   signal phyClk   : sl;
   signal phyRst   : sl;
   signal phyReady : sl;

   signal phyInitRst : sl;
   signal phyIrq     : sl;
   signal phyMdi     : sl;
   signal phyMdo     : sl := '1';

   signal extPhyRstN  : sl := '0';
   signal extPhyReady : sl := '0';

   signal speed10_100 : sl := '0';
   signal speed100    : sl := '0';
   signal linkIsUp    : sl := '0';
   signal initDone    : sl := '0';

begin

   -- Tri-state driver for phyMdio
   phyMdio <= 'Z' when phyMdo = '1' else '0';

   -- Reset line of the external phy
   phyRstN <= extPhyRstN;

   --------------------------------------------------------------------------
   -- We must hold reset for >10ms and then wait >5ms until we may talk
   -- to it (we actually wait also >10ms) which is indicated by 'extPhyReady'
   --------------------------------------------------------------------------
   U_PwrUpRst0 : entity work.PwrUpRst
      generic map(
         TPD_G          => TPD_G,
         IN_POLARITY_G  => '1',
         OUT_POLARITY_G => '0',
         DURATION_G     => getTimeRatio(STABLE_CLK_FREQ_G, 100.0))  -- 10 ms reset
      port map (
         arst   => extRst,
         clk    => stableClk,
         rstOut => extPhyRstN);

   U_PwrUpRst1 : entity work.PwrUpRst
      generic map(
         TPD_G          => TPD_G,
         IN_POLARITY_G  => '0',
         OUT_POLARITY_G => '0',
         DURATION_G     => getTimeRatio(STABLE_CLK_FREQ_G, 100.0))  -- 10 ms reset
      port map (
         arst   => extPhyRstN,
         clk    => stableClk,
         rstOut => extPhyReady);

   ----------------------------------------------------------------------
   -- The MDIO controller which talks to the external PHY must be held
   -- in reset until extPhyReady; it works in a different clock domain...
   ----------------------------------------------------------------------
   U_PhyInitRstSync : entity work.RstSync
      generic map (
         IN_POLARITY_G  => '0',
         OUT_POLARITY_G => '1')
      port map (
         clk      => phyClk,
         asyncRst => extPhyReady,
         syncRst  => phyInitRst);

   -----------------------------------------------------------------------
   -- The SaltCore does not support auto-negotiation on the SGMII link
   -- (mac<->phy) - however, the Marvell PHY (by default) assumes it does.
   -- We need to disable auto-negotiation in the PHY on the SGMII side
   -- and handle link changes (aneg still enabled on copper) flagged
   -- by the PHY...
   -----------------------------------------------------------------------
   U_PhyCtrl : entity work.Sgmii88E1111Mdio
      generic map (
         TPD_G => TPD_G,
         PHY_G => PHY_G,
         DIV_G => 100)
      port map (
         clk             => phyClk,
         rst             => phyInitRst,
         initDone        => initDone,
         speed_is_10_100 => speed10_100,
         speed_is_100    => speed100,
         linkIsUp        => linkIsUp,
         mdi             => phyMdi,
         mdc             => phyMdc,
         mdo             => phyMdo,
         linkIrq         => phyIrq);

   ----------------------------------------------------
   -- synchronize MDI and IRQ signals into 'clk' domain
   ----------------------------------------------------
   U_SyncMdi : entity work.Synchronizer
      generic map (
         TPD_G => TPD_G)
      port map (
         clk     => phyClk,
         dataIn  => phyMdio,
         dataOut => phyMdi);

   U_SyncIrq : entity work.Synchronizer
      generic map (
         TPD_G          => TPD_G,
         OUT_POLARITY_G => '0',
         INIT_G         => "11")
      port map (
         clk     => phyClk,
         dataIn  => phyIrqN,
         dataOut => phyIrq);

   U_1GigE : entity work.GigEthLvdsUltraScaleWrapper
      generic map (
         TPD_G             => TPD_G,
         -- DMA/MAC Configurations
         NUM_LANE_G        => 1,
         -- MMCM Configuration
         USE_REFCLK_G      => false,
         CLKIN_PERIOD_G    => 1.6,      -- 625.0 MHz
         DIVCLK_DIVIDE_G   => 2,        -- 312.5 MHz
         CLKFBOUT_MULT_F_G => 2.0,      -- VCO: 625 MHz
         -- AXI Streaming Configurations
         AXIS_CONFIG_G     =>(others =>  AXIS_CONFIG_G))
      port map (
         -- Local Configurations
         localMac(0)        => localMac,
         -- Streaming DMA Interface
         dmaClk(0)          => macClk,
         dmaRst(0)          => macRst,
         dmaIbMasters(0)    => obMacMaster,
         dmaIbSlaves(0)     => obMacSlave,
         dmaObMasters(0)    => ibMacMaster,
         dmaObSlaves(0)     => ibMacSlave,
         -- Misc. Signals
         extRst             => extRst,
         phyClk             => phyClk,
         phyRst             => phyRst,
         phyReady(0)        => phyReady,
         speed_is_10_100(0) => speed10_100,
         speed_is_100(0)    => speed100,
         -- MGT Clock Port
         sgmiiClkP          => phyClkP,
         sgmiiClkN          => phyClkN,
         -- MGT Ports
         sgmiiTxP(0)        => sgmiiTxP,
         sgmiiTxN(0)        => sgmiiTxN,
         sgmiiRxP(0)        => sgmiiRxP,
         sgmiiRxN(0)        => sgmiiRxN);

end mapping;
