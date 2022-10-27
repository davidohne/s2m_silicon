#!/bin/bash

# Possible Arguments:
# --nocolor will not use any colors when printing text, in case certain
#     combinations aren't readable to the user.
# --ignorechecks will ignore the results from the check and prompt the user
#     instead to decide what to do and what to skip.
# --skipprereq will skip the installation of prerequisites. This can be useful
#     if the user wants to manually install the prerequisites.

# To find out how to manually configure and set up the ADOxx based tool:
# --> Check the configuration_screen and installation_screen functions.

# Tested with:
#   macOS Catalina (10.15)

# Structure of this script:
# * First the relevant and useful variables are initialized and arguments processed.
# * Then we change to the directory where the script is executed.
# * Several functions are defined:
#   - some simple helper functions.
#   - then there's functions that make several checks and set variables.
#   - then we have functions focusing on installing the prerequisites.
#   - adoxx_logo prints a nice looking logo for the ADOxx tool.
#   - then we have functions focusing on the user interaction.
#     - startup_screen provides the information about this script.
#     - checks_screen performs the checks and lists possible possible.
#     - prerequesites_screen tries to install any prerequisites if possible.
#     - configuration_screen sets up the Wine prefix and Docker container.
#     - installation_screen installs and configures the ADOxx specific parts.
# * At the end the screen functions are executed in the desired order.

# these variables contain the details for this specific ADOxx based tool.
toolfolder="Scene2Model16_ADOxx_SA"
database="s2m16db"
licensekey="zAd-nvkz-Ynrs*nhlAOAL2pc"
shortcutfile="Scene2Model 1.6 (64-bit).app"

# these variables contain some of the other relevant locations used in the script.
# NOTE: dbinstancename, minwineversion and mindockerversion should not contain
#       whitespaces.
wineprefixdir="${HOME}/.wine_adoxx64"
dbinstancename="ADOXX15EN"
minbrewversion="0.0"
minwineversion="5.0"
mindockerversion="0.0"

installedbrewversion=""
installedwineversion=""
installeddockerversion=""


# these variables contain the results of different checks.
# we start with "everything ok/available" to only notify the user about problems that we recognise.
# note: 0 means true in bash
isroot=1
hasbrew=0
correctbrewversion=0
hasmssqltapped=0
haswine=0
correctwineversion=0
hasodbcdriver=0
hasdocker=0
correctdockerversion=0
dockerrunning=0
haswineprefix=0
hascontainer=0
hascontainerrunning=0
adoxxfolderalreadyexists=1


# some simple arguments are processed and set boolean variables.
usecolors=0
ignorechecks=1
skipprereq=1
forceop=1 # this is necessary later on when ignoring checks
for argvar in ${@}
do
	if [ "${argvar}" = "--nocolor" ]
	then
		usecolors=1
	elif [ "${argvar}" = "--ignorechecks" ]
	then
		ignorechecks=0
	elif [ "${argvar}" = "--skipprereq" ]
	then
		skipprereq=0
	fi
done

if [ ${usecolors} -eq 0 ]
then
	red=$'\e[1;31m'   # Used for errors
	blue=$'\e[1;34m'  # Used to indicate user input
	yellow=$'\e[33m'  # Used for messages that should get attention
	grey=$'\e[37m'    # Used for the ADOxx logo
	white=$'\e[0m'    # Default color of text
else
	red=''
	blue=''
	yellow=''
	grey=''
	white=''
fi
# colors not used:   green=$'\e[1;32m'   mag=$'\e[1;35m'   cyn=$'\e[1;36m'  




# adapted from http://ask.xmodulo.com/compare-two-version-numbers.html
# checks if the first version number is greater or equal than the second version number
function version_gr_or_eq { test $(echo ${@} | tr " " "\n" | sort -rV | head -n 1) == $1; }

# checks if the provided argument is something that we interpret as yes.
# if it starts with a y or Y it is considered "yes", otherwise "no".
function prompt_def_no {
	local tempval=""
	if [ $# -gt 0 ]
	then
		read -p "${*}" tempval
	else
		read -p "Yes or no? (default: No)" tempval
	fi
	tempval=$(echo ${tempval} | tr '[:upper:]' '[:lower:]')
	[ -n ${tempval} ] && [[ ${tempval} = y* ]]
}



function check_brew {
	# check if brew is available
	command -v brew &>/dev/null
	hasbrew=$?
	# check if the correct brew version is used and if necessary taps are tapped
	if [ ${hasbrew} -eq 0 ] 
	then
		installedbrewversion=$(echo "$(brew --version 2>&1)" | grep "Homebrew "| cut -d' ' -f 2-)
		version_gr_or_eq ${installedbrewversion} ${minbrewversion}
		correctbrewversion=$?

		[ "$(brew tap | grep "microsoft/mssql-release")" == "microsoft/mssql-release" ]
		hasmssqltapped=$?
	fi
}

function check_wine {
	# check if wine is available
	command -v wine64 &>/dev/null
	haswine=$?
	# check if the correct wine version is used
	if [ ${haswine} -eq 0 ]
	then
		installedwineversion=$(echo "$(wine64 --version 2>&1)" | grep "wine-" | cut -d'-' -f 2-)
		version_gr_or_eq ${installedwineversion} ${minwineversion}
		correctwineversion=$?
	fi
}

function check_odbc {
	# check if the SQL Server ODBC driver is installed
	if [ ${hasbrew} -eq 0 ] 
	then
		[ ! -z "$(brew list | grep "msodbcsql")" ]
		hasodbcdriver=$?
	else
		hasodbcdriver=1
	fi
}

function check_docker {
	# check if docker is available
	command -v docker &>/dev/null
	hasdocker=$?
	# the following checks can only be performed if docker is available
	if [ ${hasdocker} -eq 0 ]
	then
		# check if the correct docker version is used
		installeddockerversion=$(echo "$(docker --version 2>&1)" | grep "Docker version" | cut -d' ' -f 3 | sed 's/,$//')
		version_gr_or_eq ${installeddockerversion} ${mindockerversion}
		correctdockerversion=$?
		# check if docker is running
		sudo docker ps | grep "CONTAINER ID" &>/dev/null
		dockerrunning=$?
		# check if the relevant container is available
		sudo docker ps -a | grep ${dbinstancename} &>/dev/null
		hascontainer=$?
		if [ ${hascontainer} -eq 0 ]
		then
			# check if the necessary container is running
			runningcheck=$(sudo docker inspect -f '{{.State.Running}}' $dbinstancename) 2>/dev/null
			if ( [ -n "${runningcheck}" ] && [ "${runningcheck}" = "true" ] )
			then
				hascontainerrunning=0
			else
				hascontainerrunning=1
			fi
		fi
	fi
}

function perform_checks {
	# this checks if something might not be right and sets the corresponding variables

	# check if the user is root, which is not recommended
	[ $(whoami) = "root" ] &>/dev/null
	isroot=$?

	check_brew
	check_wine

	# check if the used Wine prefix is already available
	[ -d "${wineprefixdir}" ] &>/dev/null
	haswineprefix=$?

	check_docker
	check_odbc

	# check if the folder of the ADOxx based tool is already available in the Wine prefix
	[ -d "${wineprefixdir}/drive_c/Program Files/BOC/${toolfolder}" ] &>/dev/null
	adoxxfolderalreadyexists=$?
}



function install_brew {
	/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
	brew doctor

	check_brew
}

function tap_brew {
	brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
	brew update

	check_brew
}

function install_wine {
	# follow steps here: https://www.davidbaumgold.com/tutorials/wine-mac/#part-1:-install-homebrew
	if [ ${hasbrew} -eq 0 ]
	then
		brew cask install xquartz
		brew cask install wine-stable
	else
		echo "Can't install Wine because Homebrew is missing."
	fi

	check_wine
}

function install_odbc {
	# also installs other tools that are relevant like unixodbc
	HOMEBREW_NO_ENV_FILTERING=1 ACCEPT_EULA=Y brew install msodbcsql17

	check_odbc
}

function install_docker {
	if [ ${hasbrew} -eq 0 ]
	then
		brew cask install docker
	else
		echo "Can't install Docker because Homebrew is missing."
	fi

	check_docker
}

function start_docker {
	# Start Docker if it isn't running
	sudo docker ps | grep "CONTAINER ID" &> /dev/null
	if [ ! $? -eq 0 ]
	then
		echo $blue"Please give Docker some time to start."$white
		open /Applications/Docker.app
		read -p $blue"Follow instructions given by Docker and hit ENTER when it is ready and running. You can check if Docker is ready and running by clicking on the Docker icon on the menu bar (top right)."$white
	fi

	check_docker
}



function adoxx_logo {
	echo "-------------------------------------------------------------------   "$yellow"*        "$grey"#"$white
	echo "|                                                                    "$yellow"***     "$grey"###"$white
	echo "|         ADOxx Installation for macOS                              "$yellow"*****  "$grey"#####"$white
	echo "|         (Experimental Release, V0.3a)                                  "$grey"#######"$white
	echo "|                                                                      "$grey"#########"$white
	echo "-------------------------------------------------------------------  "$grey"###########"$white
}

function startup_screen {
	echo ""
	adoxx_logo
	echo ""
	echo "This script installs ADOxx or an ADOxx based tool on your 64-bit macOS based"
	echo "system using native virtualisation techniques. This means that no virtualised"
	echo "Microsoft Windows environment is required."
	echo $yellow"Before starting the installation, make sure that your system is up-to-date."$white
	echo "Provide --nocolor argument to script to omit the use of colors."
	echo "Provide --ignorechecks argument to script to skip checks and use user-prompts."
	echo "Check the README.md for more information about possible arguments."
	echo $yellow"You can stop the execution at any point by pressing CTRL+C."$white
	echo "--------------------------------------------------------------------------------"
	echo ""
	echo "Prerequisites:"
	echo "a. Internet connection: some resources are downloaded from the internet"
	echo "b. Administrative password: some steps can require administrative privileges"
	echo "c. Manual steps: in some cases manual steps before running the script are needed"
	echo "--------------------------------------------------------------------------------"
	read -p $blue"Hit ENTER to continue"$white

	echo ""
	echo "Steps performed:"
	echo "1. Performing checks: checks some prerequisites and reports possible problems."
	echo "       A short report on any encountered problems is given."
	echo "2. Install prerequisites: installs the necessary prerequisites that are missing."
	echo "       Installs Homebrew, Wine, Docker and ODBC driver if they are missing."
	echo "3. Configuration of base environment: the base system is configured."
	echo "       This sets up the necessary Wine prefix, Docker container and ODBC conn."
	echo "4. Installation of ADOxx/ADOxx based tool: installs and configures the tool."
	echo "       This copies the relevant files for the tool and sets up the database."
	echo "--------------------------------------------------------------------------------"
	echo $yellow"All installation of ADOxx/ADOxx based tools is performed without changing"
	echo "pre-exiting packages and configuration. It utilizes standard techniques and"
	echo "repositories to perform the installation."$white
	echo "--------------------------------------------------------------------------------"
	read -p $blue"Hit ENTER to continue"$white
}

function checks_screen {
	echo ""
	echo "1. Performing checks"
	echo "--------------------------------------------------------------------------------"
	echo "In this step any basic checks are performed and a report with any encountered"
	echo "issues is given. While this script tries to resolve some of those issues, others"
	echo "require to be taken care of by the user."
	echo "--------------------------------------------------------------------------------"
	read -p $blue"Hit ENTER to continue with step 1"$white
	echo ""
	if [ ${ignorechecks} -eq 0 ]
	then
		echo $red"Since checks are ignored we are also not performing any."$white
	else
		perform_checks
		echo "The following problems have been identified:"
	fi
	local hasproblems=1

	# the user is root
	if [ ${isroot} -eq 0 ]
	then
		echo $red" * This script is being executed as root. This can lead to problems when the"
		echo "   Wine prefix is being set up."$white
		hasproblems=0
	fi
	
	# we don't have brew or wrong version or tap missing
	if [ ! ${hasbrew} -eq 0 ]
	then
		echo $yellow" * The execution requires Homebrew which doesn't seem to be available. The 2nd"
		echo "   step will try to alleviate this."$white
	fi
	if [ ! ${correctbrewversion} -eq 0 ]
	then
		echo $red" * The installed Homebrew version seems to be a bit on the older side. While the"
		echo "   installation/tool still might work, it is recommended to use a newer version."
		echo "   Installed version: "$installedbrewversion", recommended version "$minbrewversion
		echo "   or higher. Updating Homebrew has to be done manually."$white
		hasproblems=0
	fi
	if [ ! ${hasmssqltapped} -eq 0 ]
	then
		echo $yellow" * A relevant source isn't tapped by Homebrew. The 2nd step will try to"
		echo "   alleviate this."$white
	fi


	# we don't have wine or the right version
	if [ ! ${haswine} -eq 0 ]
	then
		echo $yellow" * The execution requires Wine which doesn't seem to be available. The 2nd step"
		echo "   will try to alleviate this."$white
	fi
	if [ ! ${correctwineversion} -eq 0 ]
	then
		echo $red" * The installed Wine version seems to be a bit on the older side. While the"
		echo "   installation/tool still might work, it is recommended to use a newer version."
		echo "   Installed version: "$installedwineversion", recommended version "$minwineversion
		echo "   or higher. Updating Wine has to be done manually."$white
		hasproblems=0
	fi

	# we don't have the sql server ODBC driver installed
	if [ ! ${hasodbcdriver} -eq 0 ]
	then
		echo $yellow" * The SQL Server ODBC driver might not be installed. The 2nd step will try to"
		echo "alleviate this."$white
	fi

	# we don't have docker, it isn't running or the wrong version
	if [ ! ${hasdocker} -eq 0 ]
	then
		echo $yellow" * The execution uses Docker which doesn't seem to be available. The 2nd"
		echo "   step will try to alleviate this."$white
	fi
	if [ ! ${correctdockerversion} -eq 0 ]
	then
		echo $red" * The installed Docker version seems to be a bit on the older side. While the"
		echo "   installation/tool still might work, it is recommended to use a newer version."
		echo "   Installed version: "$installeddockerversion", recommended version "$mindockerversion
		echo "   or higher. Updating Docker has to be done manually."$white
		hasproblems=0
	fi
	if [ ! ${dockerrunning} -eq 0 ]
	then
		echo $yellow" * Docker doesn't seem to be running. The 2nd step will try to alleviate this."$white
	fi

	# the Wine prefix isn't set up yet
	if [ ! ${haswineprefix} -eq 0 ]
	then
		echo $yellow" * The required Wine prefix doesn't seem to be available. The 3nd step will try"
		echo "   to alleviate this."$white
	fi

	# something with the docker container isn't right yet
	if [ ! ${hascontainer} -eq 0 ]
	then
		echo $yellow" * The required Docker container doesn't seem to be set up. The 3nd step will"
		echo "   try to alleviate this."$white
	fi
	if [ ! ${hascontainerrunning} -eq 0 ]
	then
		echo $yellow" * The required Docker container doesn't seem to be running. The 3nd step will"
		echo "   try to alleviate this."$white
	fi

	# the tool folder already exists
	if [ ${adoxxfolderalreadyexists} -eq 0 ]
	then
		echo $yellow" * The folder used by this ADOxx tool already exists in the used Wine prefix."
		echo "   Later on there is the option to decide how to deal with this."$white
	fi
	echo "--------------------------------------------------------------------------------"

	# if there were serious problems that aren't addressed by the script in step 2 then allow the user to abort.
	if [ ${hasproblems} -eq 0 ]
	then
		echo "There seem to be issues that have to resolved manually."
		prompt_def_no $blue"Continue to step 2 anyway? [y/N] "$white
		if [ ! $? -eq 0 ]
		then
			exit
		fi
	fi
}

function prerequesites_screen {
	echo ""
	echo "2. Install missing prerequisites"
	echo "--------------------------------------------------------------------------------"
	echo "In this step any missing prerequisites are being installed and started."
	echo $yellow"Some user interaction might be necessary for their installation."$white
	echo "--------------------------------------------------------------------------------"
	
	if [ ${skipprereq} -eq 0 ]
	then
		echo $yellow"--skipprereq argument provided. Skipping installation of any prerequisites."$white
		echo "--------------------------------------------------------------------------------"
		return 0
	fi

	read -p $blue"Hit ENTER to continue with step 2"$white
	echo ""

	local hadtointervene=1

	# Install brew if missing
	echo "A. Installing Homebrew"
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Install Homebrew and tap necessary sources? [y/N] "$white
		forceop=$?
	fi
	if [ ! ${hasbrew} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		hadtointervene=0
		install_brew
		tap_brew
		check_odbc
	elif [ ! ${hasmssqltapped} -eq 0 ]
	then
		hadtointervene=0
		tap_brew
	else
		echo "Installation and/or tapping not necessary / skipped."
	fi
	echo "--------------------------------------------------------------------------------"
	echo ""

	# Install wine if missing
	echo "B. Installing Wine"
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Install Wine? [y/N] "$white
		forceop=$?
	fi
	if [ ! ${haswine} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		hadtointervene=0
		install_wine
	else
		echo "Installation not necessary / skipped."
	fi
	echo "--------------------------------------------------------------------------------"
	echo ""

	# Install ODBC driver
	echo "C. Installing ODBC driver"
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Install Microsoft ODBC Driver 17 for SQL Server? [y/N] "$white
		forceop=$?
	fi
	if [ ! ${hasodbcdriver} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		hadtointervene=0
		install_odbc
	else
		echo "Installation not necessary / skipped."
	fi
	echo "--------------------------------------------------------------------------------"
	echo ""

	# Install docker if missing
	echo "D. Installing Docker"
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Install Docker? [y/N] "$white
		forceop=$?
	fi
	if [ ! ${hasdocker} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		hadtointervene=0
		install_docker
	else
		echo "Installation not necessary / skipped."
	fi
	echo "--------------------------------------------------------------------------------"
	echo ""

	# Start docker if necessary
	echo "E. Starting Docker"
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Start Docker? [y/N] "$white
		forceop=$?
	fi
	# Note we check if hasdocker is false, cause that's the case where it was just installed.
	if [ ! ${hasdocker} -eq 0 ] || [ ! ${dockerrunning} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		hadtointervene=0
		start_docker
	else
		echo "Starting not necessary / skipped."
	fi
	echo "--------------------------------------------------------------------------------"
	echo ""

	local hasproblems=1
	if [ ${hadtointervene} -eq 0 ]
	then
		echo "Rerunning checks"
		if [ ${ignorechecks} -eq 0 ]
		then
			echo $red"Since checks are ignored we are also not performing any."$white
		else
			perform_checks
			# Again print a kind of report.
			echo "The following problems have been identified:"
			# we don't have brew or the right version
			if [ ! ${hasbrew} -eq 0 ]
			then
				echo $red" * The execution requires Homebrew which doesn't seem to be available. Please"
				echo "   install Homebrew version "$minbrewversion" or higher manually."$white
				hasproblems=0
			fi
			if [ ! ${correctbrewversion} -eq 0 ]
			then
				echo $red" * The installed Homebrew version seems to be a bit on the older side. While the"
				echo "   installation/tool still might work, it is recommended to use a newer version."
				echo "   Installed version: "$installedbrewversion", recommended version "$minbrewversion
				echo "   or higher. Updating Wine has to be done manually."$white
				hasproblems=0
			fi
			if [ ! ${hasmssqltapped} -eq 0 ]
			then
				echo $red" * The source for installing the ODBC driver isn't tapped by Homebrew. Please"
				echo "   tap the required ressources manually (see README.md for details)."$white
				hasproblems=0
			fi

			# we don't have wine or the right version
			if [ ! ${haswine} -eq 0 ]
			then
				echo $red" * The execution requires Wine which doesn't seem to be available. Please"
				echo "   install Wine version "$minwineversion" or higher manually."$white
				hasproblems=0
			fi
			if [ ! ${correctwineversion} -eq 0 ]
			then
				echo $red" * The installed Wine version seems to be a bit on the older side. While the"
				echo "   installation/tool still might work, it is recommended to use a newer version."
				echo "   Installed version: "$installedwineversion", recommended version "$minwineversion
				echo "   or higher. Updating Wine has to be done manually."$white
				hasproblems=0
			fi

			# we don't have the sql server ODBC connector installed
			if [ ! ${hasodbcdriver} -eq 0 ]
			then
				echo $red" * The SQL Server ODBC driver is not installed. Please install the ODBC driver"
				echo "   manually (see README.md for details)."$white
				hasproblems=0
			fi

			# we don't have docker, it isn't running or the wrong version
			if [ ! ${hasdocker} -eq 0 ]
			then
				echo $red" * The execution uses Docker which doesn't seem to be available. Please"
				echo "   install Docker version "$mindockerversion" or higher manually."$white
				hasproblems=0
			fi
			if [ ! ${correctdockerversion} -eq 0 ]
			then
				echo $red" * The installed Docker version seems to be a bit on the older side. While the"
				echo "   installation/tool still might work, it is recommended to use a newer version."
				echo "   Installed version: "$installeddockerversion", recommended version "$mindockerversion
				echo "   or higher. Updating Docker has to be done manually."$white
				hasproblems=0
			fi
			if [ ! ${dockerrunning} -eq 0 ]
			then
				echo $red" * Docker doesn't seem to be running. Please resolve this issue manually."$white
				hasproblems=0
			fi
			if [ ! ${hasproblems} -eq 0 ]
			then
				echo "Looks like all prerequisites are installed properly now."
			fi
		fi
	else
		echo "Looks like all prerequisites are already installed properly."
	fi
	echo "--------------------------------------------------------------------------------"
	# Allow the user to abort if there have been problems
	if [ ${hasproblems} -eq 0 ]
	then
		echo "There seem to be issues that have to resolved manually."
		prompt_def_no $blue"Continue to step 3 anyway? [y/N] "$white
		if [ ! $? -eq 0 ]
		then
			exit
		fi
	fi
}

function configuration_screen {
	echo ""
	echo "3. Configuration of base environment"
	echo "--------------------------------------------------------------------------------"
	echo "In this step the base environment is configured. This includes setting up the "
	echo "Wine prefix and the Docker container with the Microsoft SQL Database and"
	echo "creating the relevant ODBC connection."
	echo "--------------------------------------------------------------------------------"
	echo $yellow"This requires Homebrew, Wine and Docker to be available and running as well as"
	echo "an internet connection to pull the necessary container."$white
	echo "--------------------------------------------------------------------------------"
	read -p $blue"Hit ENTER to continue with step 3"$white
	echo ""

	echo "A. Setting up Wine prefix"
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Set up Wine prefix? [y/N] "$white
		forceop=$?
	fi
	if [ ! ${haswineprefix} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		echo "Configuration of the ADOxx Wine prefix is starting."
		echo $blue"Confirm installation requests in case required."$white
		LANG=en_US WINEARCH=win64 WINEPREFIX="${wineprefixdir}" WINEDEBUG=-all wine64 cmd /k exit
	elif [ ${haswineprefix} -eq 0 ]
	then
		echo "Wine prefix already exists."
	fi
	echo "Finished creating Wine prefix."
	echo "--------------------------------------------------------------------------------"
	echo ""

	echo "B. Setting up ADOxx Microsoft SQL Database (Express Edition) in Docker"
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Set up SQL Database? [y/N] "$white
		forceop=$?
	fi
	if [ ! ${hascontainer} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		# pull the image
		sudo docker pull mcr.microsoft.com/mssql/server:2017-latest
		# start a new container
		sudo docker run -e 'ACCEPT_EULA=Y' -e 'SA_PASSWORD=12+*ADOxx*+34' -p 1433:1433 --name ${dbinstancename} --restart always -d mcr.microsoft.com/mssql/server:2017-latest
	elif [ ${hascontainer} -eq 0 ]
	then
		echo "Container already exists."
	fi

	# We have to check if the container is running again at this point instead of relying on the old check
	if [ ! ${ignorechecks} -eq 0 ]
		then
		if [ $(sudo docker inspect -f '{{.State.Running}}' ${dbinstancename}) = "true" ]
		then
			echo $dbinstancename" container is running."
		else
			echo "Starting "$dbinstancename" container."
			echo $yellow"Press CTRL+C to abort if stuck."$white
			sudo docker start ${dbinstancename}
			while ( ! nc -z localhost 1433 )
			do
				echo "Microsoft SQL Server not yet ready - waiting for 2 second and retrying ..."
				sleep 2
			done
		fi
		echo "Finished setting up Docker container."
	fi
	echo "--------------------------------------------------------------------------------"
	echo ""

	echo "C. Creating ODBC connection."
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Create ODBC connection? [y/N] "$white
		forceop=$?
	fi
	if [ ! ${ignorechecks} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		# adds database connection if it doesn't already exist
		if [ -z "$(odbcinst -q -s | grep "${database}")" ]
		then
			odbcinst -i -s ${database} -f support64/odbctemplate.ini
		else
			echo "ODBC connection to ${database} already exists, so it won't be overwritten."
		fi
	fi
	echo "Finished creating ODBC connection."
	echo "--------------------------------------------------------------------------------"
}

function installation_screen {
	echo ""
	echo "4. Installation of ADOxx/ADOxx based tool"
	echo "--------------------------------------------------------------------------------"
	echo "In this step ADOxx/ADOxx based tool is installed and set up."
	echo "This starts with copying the relevant files of the tool, followed by the"
	echo "initialization of the database and its connection interface and concludes by"
	echo "importing the ADOxx configuration."
	echo "For this step to be successful all of the previous prerequisites and"
	echo "configurations are necessary."
	echo "--------------------------------------------------------------------------------"
	echo $yellow"ATTENTION: In this phase, the installation is performed with fewer checks."
	echo "Don't be surprised by error messages in case the installation is re-run."$white
	echo "--------------------------------------------------------------------------------"
	read -p $blue"Hit ENTER to continue with step 4"$white
	echo ""

	echo "A. Copy relevant tool files"
	overwritefiles=0
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Copy necessary files and overwrite existing ones? [y/N] "$white
		forceop=$?
	elif [ ${adoxxfolderalreadyexists} -eq 0 ]
	then
		echo "Looks like the folder already exists."
		prompt_def_no $blue"Should the files be overwritten? [y/N] or press CTRL-C to abort."$white
		overwritefiles=$?
	fi
	if [ ${overwritefiles} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		echo "Tool relevant files are copied to "$wineprefixdir"/drive_c/Program Files/BOC/"$toolfolder
		mkdir -p "${wineprefixdir}/drive_c/Program Files/BOC/"
		cp -rf "setup64/BOC/${toolfolder}" "${wineprefixdir}/drive_c/Program Files/BOC/"
	fi
	echo "Finished copying files."
	echo "--------------------------------------------------------------------------------"
	echo ""

	echo "B. Initial configuration of SQL Server DB Instance"
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Configure SQL DB Instance for this tool? [y/N] "$white
		forceop=$?
	fi
	if [ ! ${ignorechecks} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		# create a tmp folder for the installation of sql scripts
		sudo docker exec -it ${dbinstancename} mkdir -p /tmp/adoxx_install
		# create ADONIS user for db
		sudo docker cp support64/createUser.sql ${dbinstancename}:/tmp/adoxx_install
		sudo docker exec -it ${dbinstancename} /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P '12+*ADOxx*+34' -i /tmp/adoxx_install/createUser.sql
		# create a folder for the db files
		sudo docker exec -it ${dbinstancename} mkdir -p /opt/mssql/adoxx_data
		sudo docker cp support64/createDB.sql ${dbinstancename}:/tmp/adoxx_install
		sudo docker exec -it ${dbinstancename} /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P '12+*ADOxx*+34' -i /tmp/adoxx_install/createDB.sql
		echo "Database initialization is complete."
	fi
	echo "--------------------------------------------------------------------------------"
	echo ""

	echo "C. Initialize ADOxx configuration"
	if [ ${ignorechecks} -eq 0 ]
	then
		prompt_def_no $blue"Configure database for this tool? [y/N] "$white
		forceop=$?
	fi
	if [ ! ${ignorechecks} -eq 0 ] || [ ${forceop} -eq 0 ]
	then
		echo "Setting tool files as trustworthy."
		sudo xattr -r -d com.apple.quarantine "${wineprefixdir}/drive_c/Program Files/BOC/${toolfolder}"
		echo $yellow"This might take some time. If asked by your OS, please select wait."$white
		echo $blue"Confirm the success message once it's done (might hide behind some windows)."$white
		LANG=en_US WINEARCH=win64 WINEPREFIX="${wineprefixdir}" WINEDEBUG=-all wine64 "C:/Program Files/BOC/${toolfolder}/adbinst.exe" -d${database} -l${licensekey} -sSQLServer -iNO_SSO -lang2057
		cp -r "support64/${shortcutfile}" "/Applications/"
		sudo xattr -r -d com.apple.quarantine "/Applications/${shortcutfile}"
		# disable the forced password change
		sudo docker cp support64/postprocess.sql ${dbinstancename}:/tmp/adoxx_install
		sudo docker exec -it ${dbinstancename} /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P '12+*ADOxx*+34' -i /tmp/adoxx_install/postprocess.sql
		echo "Finished ADOxx configuration."
	fi
	echo "--------------------------------------------------------------------------------"
	echo ""
	echo "If all went well the application should now be properly installed."
	echo "Use the shortcut under Applications or the provided .sh file to run the tool."
	echo ""
	echo "--------------------------------------------------------------------------------"
}


# move to the script dir
cd "$(dirname "$0")"

# execution steps/screens
startup_screen
checks_screen
prerequesites_screen
configuration_screen
installation_screen

