#! perl

use strict;
use warnings;

# Implementation of ChordPro::Wx::Main_wxg details.

package ChordPro::Wx::Main;

# ChordPro::Wx::Main_wxg is generated by wxGlade and contains
# all UI associated code.

use parent qw( ChordPro::Wx::Main_wxg );

use Wx qw[:everything];
use Wx::Locale gettext => '_T';

use ChordPro;
use ChordPro::Paths;
use ChordPro::Output::Common;
use ChordPro::Utils qw( demarkup is_macos );
use File::Temp qw( tempfile );
use Encode qw(decode_utf8);

our $VERSION = $ChordPro::VERSION;

sub new {
    my $self = bless $_[0]->SUPER::new(), __PACKAGE__;

    Wx::Event::EVT_IDLE($self, $self->can('OnIdle'));
    Wx::Event::EVT_CLOSE($self, $self->can('OnClose'));

    # By default the TextCtrl on MacOS substitutes smart quotes and dashes.
    # Note that OSXDisableAllSmartSubstitutions requires an augmented
    # version of wxPerl.
    $self->{t_source}->OSXDisableAllSmartSubstitutions
      if $self->{t_source}->can("OSXDisableAllSmartSubstitutions");
    $self;
}

use constant FONTSIZE => 12;

my @fonts =
  ( { name => "Monospace",
      font => Wx::Font->new( FONTSIZE, wxFONTFAMILY_TELETYPE,
			     wxFONTSTYLE_NORMAL,
			     wxFONTWEIGHT_NORMAL ),
    },
    { name => "Serif",
      font => Wx::Font->new( FONTSIZE, wxFONTFAMILY_ROMAN,
			     wxFONTSTYLE_NORMAL,
			     wxFONTWEIGHT_NORMAL ),
    },
    { name => "Sans serif",
      font => Wx::Font->new( FONTSIZE, wxFONTFAMILY_SWISS,
			     wxFONTSTYLE_NORMAL,
			     wxFONTWEIGHT_NORMAL ),
    },
  );

my $prefctl;

# Old GTK2 version is limited due to sandboxing. GTK3 behaves normal.
my $is_macos_crippled = is_macos();

# Explicit (re)initialisation of this class.
sub init {
    my ( $self, $options ) = @_;

    $prefctl ||=
      {
       # Skip default (system, user, song) configs.
       skipstdcfg  => 1,

       # Presets.
       enable_presets => 1,
       cfgpreset      => lc(_T("Default")),

       # Custom config file.
       enable_configfile => 0,
       configfile        => "",

       # Custom library.
       enable_customlib => 0,
       customlib        => $ENV{CHORDPRO_LIB} // "",

       # New song template.
       enable_tmplfile => 0,
       tmplfile        => "",

       # Editor.
       editfont	   => 0,
       editsize	   => FONTSIZE,

       # Notation.
       notation	   => "",

       # Transpose.
       xpose_from => 0,
       xpose_to   => 0,
       xpose_acc  => 0,

       # Transcode.
       xcode	   => "",

       # PDF Viewer.
       pdfviewer   => "",

      };

    if ( $^O =~ /^mswin/i ) {
	Wx::ConfigBase::Get->SetPath("/wxchordpro");
    }
    else {
	my $cb;
	if ( $ENV{XDG_CONFIG_HOME} && -d $ENV{XDG_CONFIG_HOME} ) {
	    $cb =
	      $ENV{XDG_CONFIG_HOME} . "/wxchordpro/wxchordpro";
	}
	elsif ( -d "$ENV{HOME}/.config" ) {
	    $cb = "$ENV{HOME}/.config/wxchordpro/wxchordpro";
	    mkdir("$ENV{HOME}/.config/wxchordpro");
	}
	else {
	    $cb = "$ENV{HOME}/.wxchordpro";
	}
	unless ( -f $cb ) {
	    open( my $fd, '>', $cb );
	}
	Wx::ConfigBase::Set
	    (Wx::FileConfig->new
	     ( "WxChordPro",
	       "ChordPro_ORG",
	       $cb,
	       '',
	       wxCONFIG_USE_LOCAL_FILE,
	     ));
    }

    $self->{_verbose} = $options->{verbose};
    $self->{_trace}   = $options->{trace};
    $self->{_debug}   = $options->{debug};
    $self->{_log}     = $options->{log};

    $self->GetPreferences;
    my $font = $fonts[$self->{prefs_editfont}]->{font};
    $font->SetPointSize($self->{prefs_editsize});
    $self->{t_source}->SetFont($font);

    $self->setup_tasks();

    # Disable menu items if we cannot.
    $self->{main_menubar}->FindItem(wxID_UNDO)
      ->Enable($self->{t_source}->CanUndo);
    $self->{main_menubar}->FindItem(wxID_REDO)
      ->Enable($self->{t_source}->CanRedo);

    # On MacOS, we cannot open arbitrary files due to sandboxing
    # constraints.
    if ( $is_macos_crippled ) {
	$self->{main_menubar}->FindItem(wxID_OPEN) ->Enable(0);
    }

    Wx::Log::SetTimestamp(' ');
    if ( @ARGV ) {
	$self->openfile( shift(@ARGV) ) || return 0;
	return 1;
    }

    # Skip initial open dialog for MacOS. Use Finder calls.
    unless ( $is_macos_crippled ) {
	$self->opendialog;
    }
    $self->newfile unless $self->{_currentfile};
    return 1;
}

################ Internal methods ################

# List of available config presets (styles).
my $stylelist;
sub stylelist {
    my ( $self ) = @_;
    return $stylelist if $stylelist && @$stylelist;
    my $cfglib = CP->configdir;
    my @stylelist;
    my %stylelist;
    for my $cfglib ( @{ CP->findresdirs("config") } ) {
	next unless $cfglib && -d $cfglib;
	opendir( my $dh, $cfglib );
	foreach ( readdir($dh) ) {
	    $_ = decode_utf8($_);
	    next unless /^(.*)\.json$/;
	    my $base = $1;
	    $stylelist{$base} = $_;
	}
    }

    my $dir = $self->{prefs_customlib};
    if ( $dir && -d ( $cfglib = "$dir/config" ) ) {
	opendir( my $dh, $cfglib );
	foreach ( readdir($dh) ) {
	    $_ = decode_utf8($_);
	    next unless /^(.*)\.json$/;
	    my $base = $1;
	    $stylelist{$base} = " $_";
	}
    }

    push( @stylelist, "chordpro" ) if delete $stylelist{chordpro};
    foreach ( sort keys %stylelist ) {
	if ( $stylelist{$_} =~ /^\s+(.*)/ ) {
	    push( @stylelist, "$_ (User)" );
	}
	else {
	    push( @stylelist, "$_" );
	}
    }

    return $stylelist = \@stylelist;
}

# List of available notation systems.
my $notationlist;
sub notationlist {
    return $notationlist if $notationlist && @$notationlist;
    $notationlist = [ undef ];
    for my $cfglib ( @{ CP->findresdirs( "notes", class => "config" ) } ) {
	next unless $cfglib && -d $cfglib;
	opendir( my $dh, $cfglib );
	foreach ( sort readdir($dh) ) {
	    $_ = decode_utf8($_);
	    next unless /^(.*)\.json$/;
	    my $base = $1;
	    $notationlist->[0] = "common", next
	      if $base eq "common";
	    push( @$notationlist, $base )
	}
    }
    return $notationlist;
}

my @tasks;

sub setup_tasks {
    my ( $self ) = @_;

    my $menu = $self->{main_menubar}->FindMenu("Tasks");
    $menu = $self->{main_menubar}->GetMenu($menu);

    my @libs = @{ CP->findresdirs("tasks") };
    my $dir = $self->{prefs_customlib};
    push( @libs, "$dir/tasks" ) if $dir && -d "$dir/tasks";
    my $did;
    my %dups;
    for my $cfglib ( @libs ) {
	next unless $cfglib && -d $cfglib;
	opendir( my $dh, $cfglib );
	foreach ( readdir($dh) ) {
	    $_ = decode_utf8($_);
	    next unless /^(.*)\.(?:json|prp)$/;
	    my $base = $1;
	    my $file = File::Spec->catfile( $cfglib, $_ );

	    # Tentative title (description).
	    ( my $desc = $base ) =~ s/_/ /g;

	    # Peek in the first line.
	    my $line;
	    my $fd;
	    open( $fd, '<:utf8', $file ) and
	      $line = <$fd> and
	      close($fd);
	    if ( $line =~ m;(?://|\#)\s*(?:chordpro\s*)?task:\s*(.*);i ) {
		$desc = $1;
	    }
	    next unless $dups{$desc}++;

	    # Append to the menu, first a separator if needed.
	    $menu->AppendSeparator unless $did++;
	    my $id = Wx::NewId();
	    $menu->Append( $id, $desc, _T("Custom task: ").$desc );
	    Wx::Event::EVT_MENU
		( $self, $id,
		  sub {
		      my ( $self, $event ) = @_;
		      $self->preview( "--config", $file );
		  } );
	    push( @tasks, [ $desc, $file ] );
	}
    }
}

sub tasks { \@tasks }
sub fonts { \@fonts }

sub opendialog {
    my ($self) = @_;
    my $fd = Wx::FileDialog->new
      ($self, _T("Choose ChordPro file"),
       "", "",
       "ChordPro files (*.cho,*.crd,*.chopro,*.chord,*.chordpro,*.pro)|*.cho;*.crd;*.chopro;*.chord;*.chordpro;*.pro|All files|*.*",
       0|wxFD_OPEN|wxFD_FILE_MUST_EXIST,
       wxDefaultPosition);
    my $ret = $fd->ShowModal;
    if ( $ret == wxID_OK ) {
	$self->openfile( $fd->GetPath, 1 );
    }
    $fd->Destroy;
}

sub openfile {
    my ( $self, $file, $checked ) = @_;

    # File tests fail on Windows, so bypass when already checked.
    unless ( $checked || -f -r $file ) {
	my $md = Wx::MessageDialog->new
	  ( $self,
	    "Error opening $file: $!",
	    "File open error",
	    wxOK | wxICON_ERROR );
	my $ret = $md->ShowModal;
	$md->Destroy;
	return;
    }
    unless ( $self->{t_source}->LoadFile($file) ) {
	my $md = Wx::MessageDialog->new
	  ( $self,
	    "Error opening $file: $!",
	    "File load error",
	    wxOK | wxICON_ERROR );
	$md->ShowModal;
	$md->Destroy;
	return;
    }
    #### TODO: Get rid of selection on Windows
    $self->{_currentfile} = $file;
    if ( $self->{t_source}->GetValue =~ /^\{\s*t(?:itle)[: ]+([^\}]*)\}/m ) {
	my $title = demarkup($1);
	my $n = $self->{t_source}->GetNumberOfLines;
	Wx::LogStatus("Loaded: $title ($n line" .
		      ( $n == 1 ? "" : "s" ) .
		      ")");
	$self->{sz_source}->GetStaticBox->SetLabel($title);
    }
    $self->SetTitle( $self->{_windowtitle} = $file);

    $self->{prefs_xpose} = 0;
    $self->{prefs_xposesharp} = 0;
    return 1;
}

sub newfile {
    my ( $self ) = @_;
    undef $self->{_currentfile};

    my $file = $self->{prefs_tmplfile};
    my $content = "{title: New Song}\n\n";
    if ( $file ) {
	if ( -f -r $file ) {
	    if ( $self->{t_source}->LoadFile($file) ) {
		$content = "";
	    }
	    else {
		$content = "# Error opening template $file: $!\n\n" . $content;
	    }
	}
	else {
	    $content = "# Error opening template $file: $!\n\n" . $content;
	}
     }
    $self->{t_source}->SetValue($content) unless $content eq "";
    $self->{t_source}->SetModified(0);
    Wx::LogStatus("New file");
    $self->{prefs_xpose} = 0;
    $self->{prefs_xposesharp} = 0;
    # On MacOS, we cannot save arbitrary files due to sandboxing
    # constraints.
    if ( $is_macos_crippled ) {
	$self->{main_menubar}->FindItem(wxID_SAVE) ->Enable(0);
    }
}

my ( $preview_cho, $preview_pdf );
my ( $msgs, $fatal, $died );

sub _warn {
    Wx::LogWarning( "%s", join("",@_) );
    $msgs++;
}

sub _die {
    Wx::LogError( "%s", join("", @_) );
    $msgs++;
    $fatal++;
    $died++;
}

sub preview {
    my ( $self, @opts ) = @_;

    # We can not unlink temps because we do not know when the viewer
    # is ready. So the best we can do is reuse the files.
    unless ( $preview_cho ) {
	( undef, $preview_cho ) = tempfile( OPEN => 0 );
	$preview_pdf = $preview_cho . ".pdf";
	$preview_cho .= ".cho";
	unlink( $preview_cho, $preview_pdf );
    }

    my $mod = $self->{t_source}->IsModified;
    $self->{t_source}->SaveFile($preview_cho);
    $self->{t_source}->SetModified($mod);

    #### ChordPro

    @ARGV = ();			# just to make sure

    $msgs = $fatal = $died = 0;
    $SIG{__WARN__} = \&_warn unless $self->{_log};
#    $SIG{__DIE__}  = \&_die;

    my $haveconfig = List::Util::any { $_ eq "--config" } @opts;
    if ( $self->{prefs_skipstdcfg} ) {
	push( @ARGV, '--nodefaultconfigs' );
    }
    if ( $self->{prefs_cfgpreset} ) {
	foreach ( @{ $self->{prefs_cfgpreset} } ) {
	    push( @ARGV, '--config', $_ =~ s/ \(User\)//ir );
	    $haveconfig++;
	}
    }
    if ( $self->{prefs_enable_configfile} ) {
	$haveconfig++;
	push( @ARGV, '--config', $self->{prefs_configfile} );

    }
    if ( $self->{prefs_enablecustomlib} ) {
	$ENV{CHORDPRO_LIB} = $self->{prefs_customlib};
    }

    if ( $self->{prefs_xcode} ) {
	$haveconfig++;
	push( @ARGV, '--transcode', $self->{prefs_xcode} );
    }

    if ( $self->{prefs_notation} ) {
	$haveconfig++;
	push( @ARGV, '--config', 'notes:' . $self->{prefs_notation} );
    }

    push( @ARGV, '--noconfig' ) unless $haveconfig;

    push( @ARGV, '--output', $preview_pdf );
    push( @ARGV, '--generate', "PDF" );

    push( @ARGV, '--transpose', $self->{prefs_xpose} )
      if $self->{prefs_xpose};

    push( @ARGV, @opts ) if @opts;
    push( @ARGV, $preview_cho );

    if ( $self->{_trace} || $self->{_debug}
	 || $self->{_verbose} && $self->{_verbose} > 1 ) {
	warn( "Command line: @ARGV\n" );
	warn( "$_\n" ) for split( /\n+/, _aboutmsg() );
    }
    my $options;
    eval {
	$options = ChordPro::app_setup( "ChordPro", $VERSION );
    };
    _die($@), goto ERROR if $@ && !$died;

    $options->{verbose} = $self->{_verbose} || 0;
    $options->{trace} = $self->{_trace} || 0;
    $options->{debug} = $self->{_debug} || $self->{_debuginfo};
    $options->{diagformat} = 'Line %n, %m';
    # Actual file name.
    $options->{filesource} = $self->{_currentfile};
    $options->{silent} = 1;

    eval {
	ChordPro::main($options)
    };
    _die($@), goto ERROR if $@ && !$died;

    if ( -e $preview_pdf ) {
	Wx::LogStatus("Output generated, starting previewer");

	if ( my $cmd = $self->{prefs_pdfviewer} ) {
	    if ( $cmd =~ s/\%f/$preview_pdf/g ) {
	    }
	    elsif ( $cmd =~ /\%u/ ) {
		my $u = _makeurl($preview_pdf);
		$cmd =~ s/\%u/$u/g;
	    }
	    else {
		$cmd .= " \"$preview_pdf\"";
	    }
	    Wx::ExecuteCommand($cmd);
	}
	else {
	    my $wxTheMimeTypesManager = Wx::MimeTypesManager->new;
	    my $ft = $wxTheMimeTypesManager->GetFileTypeFromExtension("pdf");
	    if ( $ft && ( my $cmd = $ft->GetOpenCommand($preview_pdf) ) ) {
		Wx::ExecuteCommand($cmd);
	    }
	    else {
		Wx::LaunchDefaultBrowser($preview_pdf);
	    }
	}
    }

  ERROR:
    if ( $msgs ) {
	Wx::LogStatus( $msgs . " message" .
		       ( $msgs == 1 ? "" : "s" ) . "." );
	if ( $fatal ) {
	    Wx::LogError( "Fatal problems found!" );
	    return;
	}
	else {
	    Wx::LogWarning( "Problems found!" );
	}
    }
    unlink( $preview_cho );
}

sub _makeurl {
    my $u = shift;
    $u =~ s;\\;/;g;
    $u =~ s/([^a-z0-9---_\/.~])/sprintf("%%%02X", ord($1))/ieg;
    $u =~ s/^([a-z])%3a/\/$1:/i;	# Windows
    return "file://$u";
}

sub checksaved {
    my ( $self ) = @_;
    return 1 unless ( $self->{t_source} && $self->{t_source}->IsModified );
    if ( $self->{_currentfile} ) {
	my $md = Wx::MessageDialog->new
	  ( $self,
	    "File " . $self->{_currentfile} . " has been changed.\n".
	    "Do you want to save your changes?",
	    "File has changed",
	    0 | wxCANCEL | wxYES_NO | wxYES_DEFAULT | wxICON_QUESTION );
	my $ret = $md->ShowModal;
	$md->Destroy;
	return if $ret == wxID_CANCEL;
	if ( $ret == wxID_YES ) {
	    $self->saveas( $self->{_currentfile} );
	}
    }
    elsif ( $is_macos_crippled ) {
	my $md = Wx::MessageDialog->new
	  ( $self,
	    "Sorry, cannot save your changes due to MacOS constraints.",
	    "Contents has changed",
	    0 | wxOK | wxCANCEL );
	my $ret = $md->ShowModal;
	$md->Destroy;
	return if $ret == wxID_CANCEL;
    }
    else {
	my $md = Wx::MessageDialog->new
	  ( $self,
	    "Do you want to save your changes?",
	    "Contents has changed",
	    0 | wxCANCEL | wxYES_NO | wxYES_DEFAULT | wxICON_QUESTION );
	my $ret = $md->ShowModal;
	$md->Destroy;
	return if $ret == wxID_CANCEL;
	if ( $ret == wxID_YES ) {
	    return if $self->OnSaveAs == wxID_CANCEL;
	}
    }
    return 1;
}

sub saveas {
    my ( $self, $file ) = @_;
    $self->{t_source}->SaveFile($file);
    $self->SetTitle( $self->{_windowtitle} = $file);
    Wx::LogStatus( "Saved." );
}

sub GetPreferences {
    my ( $self ) = @_;
    my $conf = Wx::ConfigBase::Get;
    for ( keys( %$prefctl ) ) {
	$self->{"prefs_$_"} = $conf->Read( "preferences/$_", $prefctl->{$_} );
    }

    # Find config setting.
    my $p = lc( $self->{prefs_cfgpreset} ) || $prefctl->{cfgpreset};
    if ( ",$p" =~ quotemeta( "," . _T("Custom") ) ) {
	$self->{_cfgpresetfile} = $self->{prefs_configfile};
    }
    my @presets;
    foreach ( @{$self->stylelist()} ) {
	if ( ",$p" =~ quotemeta( "," . lc($_) ) ) {
	    push( @presets, $_ );
	}
    }
    $self->{prefs_cfgpreset} = \@presets;

    # Find transcode setting.
    $p = lc $self->{prefs_xcode} || $prefctl->{xcode};
    if ( $p ) {
	if ( $p eq lc(_T("-----")) ) {
	    $p = $prefctl->{xcode};

	}
	else {
	    my $n = "";
	    for ( @{ $self->notationlist } ) {
		next unless $_ eq $p;
		$n = $p;
		last;
	    }
	    $p = $n;
	}
    }
    $self->{prefs_xcode} = $p;
}

sub SavePreferences {
    my ( $self ) = @_;
    return unless $self;
    my $conf = Wx::ConfigBase::Get;
    local $self->{prefs_cfgpreset} = join( ",", @{$self->{prefs_cfgpreset}} );
    for ( keys( %$prefctl ) ) {
	$conf->Write( "preferences/$_", $self->{"prefs_$_"} );
    }
    $conf->Flush;
}

################ Event handlers ################

# Event handlers override the subs generated by wxGlade in the _wxg class.

sub OnOpen {
    my ( $self, $event, $create ) = @_;
    return unless $self->checksaved;

    if ( $create ) {
	$self->newfile;
    }
    else {
	$self->opendialog;
    }
}

sub OnNew {
    my( $self, $event ) = @_;
    OnOpen( $self, $event, 1 );
}

sub OnSaveAs {
    my ($self, $event) = @_;
    my $fd = Wx::FileDialog->new
      ($self, _T("Choose output file"),
       "", "",
       "*.cho",
       0|wxFD_SAVE|wxFD_OVERWRITE_PROMPT,
       wxDefaultPosition);
    my $ret = $fd->ShowModal;
    if ( $ret == wxID_OK ) {
	$self->{_currentfile} = $fd->GetPath;
	$self->{t_source}->SaveFile($fd->GetPath);
	Wx::LogStatus( "Saved." );
    }
    $fd->Destroy;
    return $ret;
}

sub OnSave {
    my ($self, $event) = @_;
    goto &OnSaveAs unless $self->{_currentfile};
    $self->saveas( $self->{_currentfile} );
}

sub OnPreview {
    my ( $self, $event ) = @_;
    $self->preview();
}

sub OnPreviewNoChords {
    my ( $self, $event ) = @_;
    $self->preview("--no-chord-grids");
}

sub OnPreviewLyricsOnly {
    my ( $self, $event ) = @_;
    $self->preview( "--lyrics-only",
		    "--define=delegates.abc.omit=1",
		    "--define=delegates.ly.omit=1" );
}

sub OnClose {
    my ( $self, $event ) = @_;
    $self->SavePreferences;
    return unless $self->checksaved;
    $self->Destroy;
}

sub OnQuit {			# Exit from menu
    my ( $self, $event ) = @_;
    $self->Close;		# will generate Close event
}

sub OnUndo {
    my ($self, $event) = @_;
    $self->{t_source}->CanUndo
      ? $self->{t_source}->Undo
	: Wx::LogStatus("Sorry, can't undo yet");
}

sub OnRedo {
    my ($self, $event) = @_;
    $self->{t_source}->CanRedo
      ? $self->{t_source}->Redo
	: Wx::LogStatus("Sorry, can't redo yet");
}

sub OnCut {
    my ($self, $event) = @_;
    $self->{t_source}->Cut;
}

sub OnCopy {
    my ($self, $event) = @_;
    $self->{t_source}->Copy;
}

sub OnPaste {
    my ($self, $event) = @_;
    $self->{t_source}->Paste;
}

sub OnDelete {
    my ($self, $event) = @_;
    my ( $from, $to ) = $self->{t_source}->GetSelection;
    $self->{t_source}->Remove( $from, $to ) if $from < $to;
}

sub OnHelp_ChordPro {
    my ($self, $event) = @_;
    Wx::LaunchDefaultBrowser("https://www.chordpro.org/chordpro/");
}

sub OnHelp_Config {
    my ($self, $event) = @_;
    Wx::LaunchDefaultBrowser("https://www.chordpro.org/chordpro/chordpro-configuration/");
}

sub OnHelp_Example {
    my ($self, $event) = @_;
    return unless $self->checksaved;
    $self->openfile( CP->findres( "swinglow.cho", class => "examples" ) );
    undef $self->{_currentfile};
    $self->{t_source}->SetModified(0);

    # On MacOS, we cannot save arbitrary files due to sandboxing
    # constraints.
    if ( $is_macos_crippled ) {
	$self->{main_menubar}->FindItem(wxID_SAVE) ->Enable(0);
    }
}

sub OnHelp_DebugInfo {
    my ($self, $event) = @_;
    $self->{_debuginfo} = $event->IsChecked;
}

sub OnPreferences {
    my ($self, $event) = @_;

    use ChordPro::Wx::PreferencesDialog;
    $self->{d_prefs} ||= ChordPro::Wx::PreferencesDialog->new($self, -1, "Preferences");
    my $ret = $self->{d_prefs}->ShowModal;
    $self->SavePreferences if $ret == wxID_OK;
}

#               C      D      E  F      G      A        B C
my @xpmap = qw( 0 1  1 2 3  3 4  5 6  6 7 8  8 9 10 10 11 12 );
my @sfmap = qw( 0 7 -5 2 9 -3 4 -1 6 -6 1 8 -4 3 10 -2  5 0  );

sub OnPreviewMore {
    my ($self, $event) = @_;

    use ChordPro::Wx::RenderDialog;
    my $d = $self->{d_render} ||= ChordPro::Wx::RenderDialog->new($self, -1, "Tasks");
    my $ret = $d->ShowModal;
    return unless $ret == wxID_OK;
    my @args;
    if ( $d->{cb_task_no_diagrams}->IsChecked ) {
	push( @args, "--no-chord-grids" );
    }
    if ( $d->{cb_task_lyrics_only}->IsChecked ) {
	push( @args, "--lyrics-only",
	      "--define=delegates.abc.omit=1",
	      "--define=delegates.ly.omit=1" );
    }
    if ( $d->{cb_task_decapo}->IsChecked ) {
	push( @args, "--decapo" );
    }

    # Transpose.
    my $xpose_from = $xpmap[$d->{ch_xpose_from}->GetSelection];
    my $xpose_to   = $xpmap[$d->{ch_xpose_to  }->GetSelection];
    my $xpose_acc  = $d->{ch_acc}->GetSelection;
    my $n = $xpose_to - $xpose_from;
    $n += 12 if $n < 0;
    $n += 12 if $xpose_acc == 1; # sharps
    $n -= 12 if $xpose_acc == 2; # flats

    push( @args, "--transpose=$n" );



    my $i = 0;
    for ( @tasks ) {
	if ( $d->{"cb_customtask_$i"}->IsChecked ) {
	    push( @args, "--config", $_->[1] );
	}
	$i++;
    }
    $self->preview( @args );
}

sub OnText {
    my ($self, $event) = @_;
    $self->{t_source}->SetModified(1);
}

sub _aboutmsg {
    my ( $self ) = @_;
    my $firstyear = 2016;
    my $year = 1900 + (localtime(time))[5];
    if ( $year != $firstyear ) {
	$year = "$firstyear,$year";
    }

    # Sometimes version numbers are localized...
    my $dd = sub { my $v = $_[0]; $v =~ s/,/./g; $v };

    my $msg = join
      ( "",
	"ChordPro Preview Editor version ",
	$dd->($ChordPro::VERSION),
	"\n",
	"https://www.chordpro.org\n",
	"Copyright $year Johan Vromans <jvromans\@squirrel.nl>\n",
	"\n",
	"GUI designed with wxGlade\n\n",
	"Run-time information:\n",
	$::config->{settings}
	? ::runtimeinfo()
	: "  Not yet available (try again later)\n"
      );

    return $msg;
}

sub xOnAbout {
    my ($self, $event) = @_;

    my $md = Wx::MessageDialog->new
      ( $self, _aboutmsg(),
	"About ChordPro",
	wxOK|wxICON_INFORMATION,
	wxDefaultPosition);
    $md->ShowModal;
    $md->Destroy;
}

sub OnAbout {
    my ($self, $event) = @_;

    # Need a custom dialog since the mesage doesn't look well in
    # a non-proportional font.
    my $md = AboutDialog->new
      ( $self, -1, "About ChordPro",
	wxDefaultPosition, wxDefaultSize, undef,
	"About",
	_aboutmsg()
      );
    $md->ShowModal;
    $md->Destroy;
}

sub OnIdle {
    my ( $self, $event ) = @_;
    my $f = $self->{_windowtitle} // "";
    $f = "*$f" if $self->{t_source}->IsModified;
    $self->SetTitle($f);
}

################ End of Event handlers ################

package AboutDialog;

use Wx qw[:everything];
use parent -norequire, qw(Wx::Dialog);
use strict;

sub new {
    my( $self, $parent, $id, $title, $pos, $size, $style, $name, $text ) = @_;
    $parent = undef              unless defined $parent;
    $id     = -1                 unless defined $id;
    $title  = ""                 unless defined $title;
    $pos    = wxDefaultPosition  unless defined $pos;
    $size   = wxDefaultSize      unless defined $size;
    $name   = ""                 unless defined $name;

    # begin wxGlade: MyDialog::new
    $style = wxDEFAULT_DIALOG_STYLE
        unless defined $style;

    $self = $self->SUPER::new( $parent, $id, $title, $pos, $size, $style, $name );

    # Infer size from text.
    my ( $lc, $ll ) = ( 0, 0 );
    for ( split( /[\r\n]+/, $text ) ) {
	$lc++;
	$ll = length($_) if length($_) > $ll;
    }
    $self->SetSize(Wx::Size->new(10*$ll, 24*$lc));

    $self->SetTitle("About ChordPro");
    $self->SetFont(Wx::Font->new(11, wxFONTFAMILY_DEFAULT, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL, 0, ""));

    $self->{sizer_1} = Wx::BoxSizer->new(wxVERTICAL);

    $text =~ s/[\r\n]+$//;
    $self->{text} = Wx::TextCtrl->new($self, wxID_ANY, $text, wxDefaultPosition, wxDefaultSize, wxTE_MULTILINE|wxTE_READONLY);
    $self->{text}->SetFont(Wx::Font->new(11, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL, 0, ""));
    $self->{text}->SetInsertionPoint(0);
    $self->{sizer_1}->Add($self->{text}, 1, wxEXPAND|wxLEFT|wxRIGHT|wxTOP, 5);

    $self->{sizer_2} = Wx::BoxSizer->new(wxHORIZONTAL);
    $self->{sizer_1}->Add($self->{sizer_2}, 0, wxALIGN_RIGHT|wxALL, 4);

    $self->{sizer_2}->Add(1, 1, 0, wxEXPAND, 0);

    $self->{button_OK} = Wx::Button->new($self, wxID_OK, "");
    $self->{button_OK}->SetDefault();
    $self->{sizer_2}->Add($self->{button_OK}, 0, 0, 0);

    $self->SetSizer($self->{sizer_1});

    $self->SetAffirmativeId($self->{button_OK}->GetId());

    $self->Layout();
    # end wxGlade
    return $self;

}

# end of class AboutDialog

1;
