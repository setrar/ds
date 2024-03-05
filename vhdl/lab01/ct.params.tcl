#
# Copyright © Telecom Paris
# Copyright © Renaud Pacalet (renaud.pacalet@telecom-paris.fr)
# 
# This file must be used under the terms of the CeCILL. This source
# file is licensed as described in the file COPYING, which you should
# have received as part of this distribution. The terms are also
# available at:
# https://cecill.info/licences/Licence_CeCILL_V2.1-en.html
#

# edit the following assignments to declare the list of VHDL source files and
# the IO ports

# list of design units: FILE LIBRARY (paths relative to vhdl/)
array set dus {
    lab01/ct.vhd work
}

# list of external ports: NAME { PIN IO_STANDARD }
array set ios {
	switch0  {}
	wire_in  {}
	wire_out {}
	led[0]   {}
	led[1]   {}
	led[2]   {}
	led[3]   {}
}
