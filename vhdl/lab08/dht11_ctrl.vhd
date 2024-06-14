-- MASTER-ONLY: DO NOT MODIFY THIS FILE
--
-- Copyright © Telecom Paris
-- Copyright © Renaud Pacalet (renaud.pacalet@telecom-paris.fr)
-- 
-- This file must be used under the terms of the CeCILL. This source
-- file is licensed as described in the file COPYING, which you should
-- have received as part of this distribution. The terms are also
-- available at:
-- https://cecill.info/licences/Licence_CeCILL_V2.1-en.html
--

library ieee;
use ieee.std_logic_1164.all;
-- For the vector and arithmetic computations (needed for the checksum verification), we use the numeric_std_unsigned package of library ieee. It simply
-- overloads the arithmetic operators (in their unsigned version) for the std_ulogic_vector type.
use ieee.numeric_std_unsigned.all;

-- Immediate translation of the specification.
entity dht11_ctrl is
    generic(
        f_mhz:    positive := 125;
        start_us: positive := 18000;
        warm_us:  positive := 1000000
    );
    port(
        clk:     in  std_ulogic;
        sresetn: in  std_ulogic;
        data_in: in  std_ulogic;
        force0:  out std_ulogic;
        dso:     out std_ulogic;
        tp:      out std_ulogic_vector(7 downto 0);
        rh:      out std_ulogic_vector(7 downto 0);
        cerr:    out std_ulogic
    );
end entity dht11_ctrl;

architecture rtl of dht11_ctrl is

    -- Global picture:
    --
    -- We use only 3 states for the "brain" state machine. "idle" is the reset state and the state in which we wait for the warm-up time ("warm_us"
    -- microseconds). "start" is the state in which we force the data line low for "start_us" microseconds to launch a new acquisition. "run" is the state in
    -- which we receive the sensed data from the sensor.
    --
    -- The counter ("c") is forced to zero during the "start" command. Else, it is incremented at each falling edge ("fe" = 1) of the data line. So, its maximum
    -- value is 42 during the last low pulse of the data line and during the following warm-up:
    --
    -- protocol phase: warm-up .    start    . ack1  .  ack2 . bit39 . bit38     ...       . bit0  .  warm-up
    --                         .             .       .       .       .           ...       .       .
    -- data_in:        --------+             +---+   +---+   +---+   +---+   +-- ... --+   +---+   +-------------
    --                         |             |   |   |   |   |   |   |   |   |   ...   |   |   |   |
    --                         +-------------+   +---+   +---+   +---+   +---+   ...   +---+   +---+
    --                         .             .   .       .       .       .       ...   .       .   .
    -- cnt:            0 or 42 .      0      . 0 .   1   .   2   .   3   .       ...   .  41   . 42.   42
    -- state:          idle    .    start    .                      run                            .   idle

    type state_t is (idle, start, run);
    constant cmax: natural := 42;

    signal state:   state_t;                        -- Current state of the "brain" state machine
    signal shift:   std_ulogic;                     -- "shift" control input of the shift register (shift left by one position)
    signal din:     std_ulogic;                     -- "din" serial input of the shift register (enters on the right)
    signal reg:     std_ulogic_vector(23 downto 0); -- Parallel output of the shift register (24 bits, 8 for each of "rh", "tp" and checksum byte)
    signal tz:      std_ulogic;                     -- "tz" control input of the timer (reinitialize to zero)
    signal t:       natural range 0 to warm_us;     -- Current value of the timer
    signal re:      std_ulogic;                     -- Rising edge indicator generated by the "edge" module
    signal fe:      std_ulogic;                     -- Falling edge indicator generated by the "edge" module
    signal cz:      std_ulogic;                     -- "cz" control input of the counter (reinitialize to zero)
    signal inc:     std_ulogic;                     -- "inc" control input of the counter (increment if not equal to "cmax")
    signal c:       natural range 0 to cmax;        -- Current value of the counter

begin

    -- At all time the "rh" output (relative humidity) if the leftmost byte of the shift register output. Most of the time this is wrong but we don't care
    -- because the environment considers "rh" only when "dso" is high and we will guarantee that "dso" is high when the acquisition is finished.
    rh     <= reg(23 downto 16);
    -- Same for "tp" (temperature)
    tp     <= reg(15 downto 8);

    -- We always compute the "cerr" output (checksum error), combinatorially from the current content of the shift register. As for "rh" and "tp" this is wrong
    -- most of the time but we don't care because we will guarantee that it is correct when "dso" is high. Thanks to "ieee.numeric_std_unsigned", computing
    -- "cerr" is easy.
    cerr   <= '1' when reg(23 downto 16) + reg(15 downto 8) /= reg(7 downto 0) else '0';

    tz     <= '1' when state = idle and t = warm_us else            -- We reinitialize the timer at the end of the warm-up time
              '1' when state /= idle and t = start_us else          -- or at the end of the "start" command, or if the timer reaches "start_us" (this is part
                                                                    -- of the "watch dog" mechanism that aborts the current acquisition in case of failure)
              '1' when state = run and fe = '1' else                -- or, during the acquisition, at each falling edge
              '1' when state = run and (re = '1' and c = cmax) else -- or at the end of the acquisition
              '0';                                                  -- else we let it run

    -- We consider that the next input bit is "one" if the timer is larger or equal 100, else we consider that it is a "zero". As we measure the time between
    -- falling edges of the data line this indeed corresponds to the specifications, except during the warm-up and the "start" command but as we do not shift
    -- the shift register during these, the value of "din" does not matter.
    din    <= '1' when t >= 100 else '0';

    -- We shift during the acquisition ("state" = "run") on falling edges of the data line ("fe" = 1), but only for the bits we are interested in: the two
    -- acknowledge ("c" = 0 or "c" = 1), the 8 bits of the integer part of relative humidity (2 <= "c" <= 9), the 8 bits of the integer part of temperature
    -- (18 <= "c" <= 25) and the last bits containing the checksum byte (34 <= "c" <= 42). We could have more accurately written:
    --   shift <= '1' when state = run and fe = '1' and ((2 <= c and c <= 9) or (18 <= c and c <= 25) or (34 <= c and c <= 41)) else '0';
    -- But this would be slightly more complicated (2 more numeric comparisons), so the synthesized hardware would probably be a bit larger and slower.
    -- Moreover, it would give the same final result because:
    -- 1. Our shift register contains only 24 bits (not 26), so the 2 acknowledge are shifted in but finally discarded (they fall out on the left).
    -- 2. When "state" = "run" and "c" = 42 there is no falling edge of the data line, so there is no shift.
    shift  <= '1' when state = run and fe = '1' and (c <= 9 or (18 <= c and c <= 25) or 34 <= c) else '0';

    -- Force counter to zero during the "start" command.
    cz     <= '1' when state = start else '0';

    -- Increment counter during acquisition ("state" = "run"), on each falling edge of the data line ("fe" = 1).
    inc    <= '1' when state = run and fe = '1' else '0';

    -- Force data line to zero during the "start" command.
    force0 <= '0' when state = start else '1';

    -- Acquisition finishes during acquisition ("state" = "run"), when "c" is maximum ("cmax" = 42) and there is the final rising edge of the data line
    -- ("re" = 1).
    dso    <= '1' when state = run and c = cmax and re = '1' else '0';

    -- The state register and next state computation of the "brain" state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if sresetn = '0' then
                state  <= idle;
            else
                case state is
                    when idle =>
                        if t = warm_us then
                            state  <= start;
                        end if;
                    when start =>
                        if t = start_us then
                            state  <= run;
                        end if;
                    when run =>
                        if (re = '1' and c = cmax) or t = start_us then
                            state <= idle;
                        end if;
                end case;
            end if;
        end if;
    end process;

    sr0: entity work.sr(rtl)
    generic map(
        n => 24
    )
    port map(
        clk     => clk,
        sresetn => sresetn,
        shift   => shift,
        din     => din,
        dout    => reg
    );

    timer0: entity work.timer(rtl)
    generic map(
        f_mhz  => f_mhz,
        max_us => warm_us
    )
    port map(
        clk     => clk,
        sresetn => sresetn,
        tz      => tz,
        t       => t
    );

    edge0: entity work.edge(rtl)
    port map(
        clk     => clk,
        sresetn => sresetn,
        data_in => data_in,
        re      => re,
        fe      => fe
    );

    counter0: entity work.counter(rtl)
    generic map(
        cmax => cmax
    )
    port map(
        clk     => clk,
        sresetn => sresetn,
        cz      => cz,
        inc     => inc,
        c       => c
    );

end architecture rtl;

-- vim: set tabstop=4 softtabstop=4 shiftwidth=4 expandtab textwidth=0:
