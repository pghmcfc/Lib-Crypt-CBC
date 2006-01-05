package Crypt::CBC;

use Digest::MD5 'md5';
use Carp;
use strict;
use vars qw($VERSION);
$VERSION = '2.17';

use constant RANDOM_DEVICE => '/dev/urandom';

sub new {
    my $class = shift;

    my $options = {};

    # hashref arguments
    if (ref $_[0] eq 'HASH') {
      $options = shift;
    }

    # CGI style arguments
    elsif ($_[0] =~ /^-[a-zA-Z]{1,20}$/) {
      my %tmp = @_;
      while ( my($key,$value) = each %tmp) {
	$key =~ s/^-//;
	$options->{lc $key} = $value;
      }
    }

    else {
	$options->{key}    = shift;
	$options->{cipher} = shift;
    }

    # "key" is a misnomer here, because it is actually usually a passphrase that is used
    # to derive the true key
    my $pass = $options->{key};
    croak "Please provide an encryption/decryption key" unless defined $pass;

    # confusing logic, but if the regenerate_key option is present but false, we
    # use the passphrase for the key
    my $key  = $pass if $options->{literal_key}
                 or (exists $options->{regenerate_key} && !$options->{regenerate_key});
    my $salt = $options->{salt};

    # if salt is equal to the string "1", then we replace it with random bytes
    $salt = $class->_get_random_bytes(8) if $salt and $salt eq '1';

    my $prepend_header = 1;
    for ('prepend_iv','add_header') {
      $prepend_header = 0 if exists $options->{$_} && !$options->{$_};
    }

    if (!$prepend_header) {
      croak "You must manually specify an initialization vector (-iv option) when using -add_header=>0"
	unless defined $options->{iv};
      croak "You must not use -salt=>1 when using -add_header=>0; either specify no salt or set the salt manually with -salt=>\"some salt\""
	if defined $options->{salt} && $options->{salt} eq '1';
    }

    # note: iv will be autogenerated by start() if not specified in options
    my $iv = $options->{iv};
       croak "Initialization vector must be 8 bytes" if $prepend_header && defined $iv && length $iv != 8;

    my $cipher = $options->{cipher};
    $cipher = 'Crypt::DES' unless $cipher;
    $cipher = $cipher=~/^Crypt::/ ? $cipher : "Crypt::$cipher";
    eval "require $cipher; 1" or croak "Couldn't load $cipher: $@";

    # some crypt modules use the class Crypt::, and others don't
    $cipher =~ s/^Crypt::// unless $cipher->can('keysize');

    my $ks        = $options->{keysize};
    my $bs        = $options->{blocksize};
    my $legacy_iv = $options->{legacy_iv};

    $ks ||= eval {$cipher->keysize};
    $bs ||= eval {$cipher->blocksize};

    my $padding = $options->{padding} || 'standard';

    if ($padding && ref($padding) eq 'CODE') {
      # check to see that this code does its padding correctly
      for my $i (1..$bs-1) {
	my $rbs = length($padding->(" "x$i,$bs,'e'));
	croak "padding method callback does not behave properly: expected $bs bytes back, got $rbs bytes back." 
	  unless ($rbs == $bs);
      }
    } else {
      $padding = $padding eq 'null'          ? \&_null_padding
	        :$padding eq 'space'         ? \&_space_padding
		:$padding eq 'oneandzeroes'  ? \&_oneandzeroes_padding
                :$padding eq 'standard'      ? \&_standard_padding
	        :croak "'$padding' padding not supported.  See perldoc Crypt::CBC for instructions on creating your own.";
    }

    # Some of the cipher modules are busted and don't report the
    # keysize (well, Crypt::Blowfish in any case).  If we detect
    # this, and find the blowfish module in use, then assume 56.
    # Otherwise assume the least common denominator of 8.
    $ks ||= $cipher =~ /blowfish/i ? 56 : 8;
    $bs ||= $ks;

    if (defined $key && length($key) > $ks) {
      carp "keysize is greater than allowed keysize of $ks for cipher $cipher - using only first $ks bytes";
      $key = substr($key, 0, $ks);
    }

    my $pcbc = $options->{'pcbc'};

    return bless {'cipher'     => $cipher,
		  'passphrase' => $pass,
		  'key'        => $key,
		  'iv'         => $iv,
		  'salt'       => $salt,
		  'padding'    => $padding,
		  'blocksize'  => $bs,
		  'keysize'    => $ks,
                  'prepend_header' => $prepend_header,
		  'legacy_iv' => $legacy_iv,
                  'pcbc'       => $pcbc,
		  },$class;
}

sub encrypt (\$$) {
    my ($self,$data) = @_;
    $self->start('encrypting');
    my $result = $self->crypt($data);
    $result .= $self->finish;
    $result;
}

sub decrypt (\$$){
    my ($self,$data) = @_;
    $self->start('decrypting');
    my $result = $self->crypt($data);
    $result .= $self->finish;
    $result;
}

sub encrypt_hex (\$$) {
    my ($self,$data) = @_;
    return join('',unpack 'H*',$self->encrypt($data));
}

sub decrypt_hex (\$$) {
    my ($self,$data) = @_;
    return $self->decrypt(pack'H*',$data);
}

# call to start a series of encryption/decryption operations
sub start (\$$) {
    my $self = shift;
    my $operation = shift;
    croak "Specify <e>ncryption or <d>ecryption" unless $operation=~/^[ed]/i;

    $self->{'buffer'} = '';
    $self->{'decrypt'} = $operation=~/^d/i;
}

# call to encrypt/decrypt a bit of data
sub crypt (\$$){
    my $self = shift;
    my $data = shift;

    my $result;

    croak "crypt() called without a preceding start()"
      unless exists $self->{'buffer'};

    my $d = $self->{'decrypt'};

    unless ($self->{civ}) { # block cipher has not yet been initialized
      $result = $self->_generate_iv_and_cipher_from_datastream(\$data)      if $d;
      $result = $self->_generate_iv_and_cipher_from_options()           unless $d;
    }

    my $iv = $self->{'civ'};
    $self->{'buffer'} .= $data;

    my $bs = $self->{'blocksize'};

    return $result unless (length($self->{'buffer'}) >= $bs);

    my @blocks = unpack("a$bs "x(int(length($self->{'buffer'})/$bs)) . "a*", $self->{'buffer'});
    $self->{'buffer'} = '';

    if ($d) {  # when decrypting, always leave a free block at the end
      $self->{'buffer'} = length($blocks[-1]) < $bs ? join '',splice(@blocks,-2) : pop(@blocks);
    } else {
      $self->{'buffer'} = pop @blocks if length($blocks[-1]) < $bs;  # what's left over
    }

    foreach my $block (@blocks) {
      if ($d) { # decrypting
	$result .= $iv = $iv ^ $self->{'crypt'}->decrypt($block);
	$iv = $block unless $self->{pcbc};
      } else { # encrypting
	$result .= $iv = $self->{'crypt'}->encrypt($iv ^ $block);
      }
      $iv = $iv ^ $block if $self->{pcbc};
    }
    $self->{'civ'} = $iv;	        # remember the iv
    return $result;
}

# this is called at the end to flush whatever's left
sub finish (\$) {
    my $self = shift;
    my $bs    = $self->{'blocksize'};
    my $block = defined $self->{'buffer'} ? $self->{'buffer'} : '';

    $self->{civ} ||= '';

    my $result;
    if ($self->{'decrypt'}) { #decrypting
	$block = length $block ? pack("a$bs",$block) : ''; # pad and truncate to block size
	
	if (length($block)) {
	  $result = $self->{'civ'} ^ $self->{'crypt'}->decrypt($block);
	  $result = $self->{'padding'}->($result, $bs, 'd');
	} else {
	  $result = '';
	}

    } else { # encrypting
      $block  = $self->{'padding'}->($block,$bs,'e') || '';
      $result = length $block ? $self->{'crypt'}->encrypt($self->{'civ'} ^ $block) : '';
    }
    delete $self->{'civ'};
    delete $self->{'buffer'};
    return $result;
}

# this subroutine will generate the actual {en,de}cryption key, the iv
# and the block cipher object.  This is called when reading from a datastream
# and so it uses previous values of salt or iv if they are encoded in datastream
# header
sub _generate_iv_and_cipher_from_datastream {
  my $self         = shift;
  my $input_stream = shift;
  my $ivs          = $self->iv_size;

  # if the input stream contains the salt, then it is used to derive the
  # IV and the encryption key from the passphrase
  if ($self->{prepend_header}) {
    if (my($salt) = $$input_stream =~ /^Salted__(.{8})/s) {
      $self->{salt} = $salt;          # Replace manually-specified salt
      undef $self->{key};             # reset the key and iv
      undef $self->{iv};
      substr($$input_stream,0,16) = '';
    }

    # if the input stream contains the IV, then we use it to set the IV
    elsif ( my($iv) = $$input_stream =~ /^RandomIV(.{$ivs})/s) {
      undef $self->{salt};              # message contents overrides salt option
      $self->{'iv'} = $iv;
      substr($$input_stream,0,8+$ivs) = ''; # truncate
    }

    if (my $salt = $self->{salt}) {
      my ($key,$iv) = $self->_salted_key_and_iv($self->{passphrase},$salt);
      $self->{key}  ||= $key;   # don't replace manually-specified key
      $self->{iv}   ||= $iv;    # don't replace manually-specified IV
    } else {
      $self->{key}  ||= $self->_key_from_key($self->{passphrase});  # don't replace manually-specified key
    }

  } else {
    $self->{key}    ||= $self->_key_from_key($self->{passphrase});
  }

  # we should have the key and iv now, or we are dead in the water
  croak "Cipher stream did not contain IV or salt, and you did not specify these values in new()"
    unless $self->{key} && $self->{iv};

  $self->{civ} = $self->{iv};  # 'civ' == "current IV"

  # now we can generate the crypt object itself
  $self->{crypt} = $self->{cipher}->new($self->{key})
    or croak "Could not create $self->{cipher} object: $@";

  return '';
}

sub _generate_iv_and_cipher_from_options {
  my $self   = shift;
  my $blocksize = $self->blocksize;

  my $result = '';

  # if salt is provided, then we use that to generate our key and iv
  if (my $salt = $self->{salt}) {
    my ($key,$iv) = $self->_salted_key_and_iv($self->{passphrase},$salt);
    $self->{key} ||= $key;
    $self->{iv}  ||= $iv;
    $result  = "Salted__${salt}" if $self->{'prepend_header'};
  }

  else {
    $self->{key} ||= $self->_key_from_key($self->{passphrase});
    $self->{iv}  ||= $self->_get_random_bytes($self->iv_size);
    $result = "RandomIV$self->{iv}" if $self->{'prepend_header'};
  }

  croak "key and/or iv are missing" unless $self->{key} && $self->{iv};

  $self->{crypt} = $self->{cipher}->new($self->{key})
    or croak "Could not create $self->{cipher} object: $@";
  $self->{'civ'} = $self->{'iv'};

  return $result;
}

sub _key_from_key {
  my $self  = shift;
  my $pass  = shift;
  my $ks    = $self->{keysize};

  my $material = md5($pass);
  while (length($material) < $ks)  {
    $material .= md5($material);
  }
  return substr($material,0,$ks);
}

sub _salted_key_and_iv {
  my $self = shift;
  my ($pass,$salt)  = @_;

  croak "Salt must be 8 bytes long" unless length $salt == 8;

  my $key_len = $self->{keysize};
  my $iv_len  = $self->{blocksize};

  my $desired_len = $key_len+$iv_len;

  my $data  = '';
  my $d = '';

  while (length $data < $desired_len) {
    $d = md5($d . $pass . $salt);
    $data .= $d;
  }
  return (substr($data,0,$key_len),substr($data,$key_len,$iv_len));
}

sub _get_random_bytes {
  my $self   = shift;
  my $length = shift;
  my $result;

  if (-r RANDOM_DEVICE && open(F,RANDOM_DEVICE)) {
    read(F,$result,$length);
    close F;
  } else {
    $result = pack("C*",map {rand(256)} 1..$length);
  }
  $result;
}

sub _standard_padding ($$$) {
  my ($b,$bs,$decrypt) = @_;
  $b = length $b ? $b : '';
  if ($decrypt eq 'd') {
     substr($b, -unpack("C",substr($b,-1)))='';
     return $b;
  }
  my $pad = $bs - length($b) % $bs;
  return $b . pack("C*",($pad)x$pad);
}

sub _space_padding ($$$) {
  my ($b,$bs,$decrypt) = @_;
  return unless length $b;
  $b = length $b ? $b : '';
  if ($decrypt eq 'd') {
     $b=~ s/ *$//s;
     return $b;
  }
  return $b . pack("C*", (32) x ($bs - length($b) % $bs));
}

sub _null_padding ($$$) {
  my ($b,$bs,$decrypt) = @_;
  return unless length $b;
  $b = length $b ? $b : '';
  if ($decrypt eq 'd') {
     $b=~ s/\0*$//s;
     return $b;
  }
  return $b . pack("C*", (0) x ($bs - length($b) % $bs));
}

sub _oneandzeroes_padding ($$$) {
  my ($b,$bs,$decrypt) = @_;
  return unless length $b;
  $b = length $b ? $b : '';
  if ($decrypt eq 'd') {
     my $hex = unpack("H*", $b);
     $hex =~ s/80*$//s;
     return pack("H*", $hex);
  }
  return $b . pack("C*", 128, (0) x ($bs - length($b) % $bs - 1) );
}

sub get_initialization_vector (\$) {
  my $self = shift;
  return $self->{'iv'};
}

sub set_initialization_vector (\$$) {
  my $self = shift;
  my $iv = shift;
	
  croak "Initialization vector must be 8 bytes" unless (length($iv) == 8);
  $self->{'iv'} = $iv;
}

sub salt {
  my $self = shift;
  my $d    = $self->{salt};
  $self->{salt} = shift if @_;
  $d;
}

sub iv {
  my $self = shift;
  my $d    = $self->{iv};
  $self->{iv} = shift if @_;
  $d;
}

sub key {
  my $self = shift;
  my $d    = $self->{key};
  $self->{key} = shift if @_;
  $d;
}

sub passphrase {
  my $self = shift;
  my $d    = $self->{passphrase};
  if (@_) {
    undef $self->{key};
    undef $self->{iv};
    $self->{passphrase} = shift;
  }
  $d;
}

sub cipher    { shift->{cipher}    }
sub padding   { shift->{padding}   }
sub keysize   { shift->{keysize}   }
sub blocksize { shift->{blocksize} }
sub pcbc      { shift->{pcbc}      }
sub legacy_iv { shift->{legacy_iv} }
sub iv_size   {
  my $self = shift;
  return 8 if $self->legacy_iv;
  return      $self->blocksize;
}

1;
__END__

=head1 NAME

Crypt::CBC - Encrypt Data with Cipher Block Chaining Mode

=head1 SYNOPSIS

  use Crypt::CBC;
  $cipher = Crypt::CBC->new( -key    => 'my secret key',
			     -cipher => 'Blowfish',
			     -salt   => 1,
			    );

  $ciphertext = $cipher->encrypt("This data is hush hush");
  $plaintext = $cipher->decrypt($ciphertext);

  $cipher->start('encrypting');
  open(F,"./BIG_FILE");
  while (read(F,$buffer,1024)) {
      print $cipher->crypt($buffer);
  }
  print $cipher->finish;


=head1 DESCRIPTION

This module is a Perl-only implementation of the cryptographic cipher
block chaining mode (CBC).  In combination with a block cipher such as
DES or IDEA, you can encrypt and decrypt messages of arbitrarily long
length.  The encrypted messages are compatible with the encryption
format used by B<SSLeay>, and can be made compatible with the newer
B<OpenSSL> package by specifying the B<-salt> argument.

To use this module, you will first create a Crypt::CBC cipher object with
new().  At the time of cipher creation, you specify an encryption key
to use and, optionally, a block encryption algorithm.  You will then
call the start() method to initialize the encryption or decryption
process, crypt() to encrypt or decrypt one or more blocks of data, and
lastly finish(), to pad and encrypt the final block.  For your
convenience, you can call the encrypt() and decrypt() methods to
operate on a whole data value at once.

=head2 new()

  $cipher = Crypt::CBC->new( -key    => 'my secret key',
			     -cipher => 'Blowfish',
			     -salt   => 1
			   );

  # or (for compatibility with versions prior to 2.13)
  $cipher = Crypt::CBC->new( {key    => 'my secret key',
			      cipher => 'Blowfish',
			      salt   => 1}
			   );


  # or (for compatibility with versions prior to 2.0)
  $cipher = new Crypt::CBC('my secret key','Blowfish');

The new() method creates a new Crypt::CBC object. It accepts a list of
-argument => value pairs selected from the following list:

  Argument        Description
  --------        -----------

  -key            The encryption/decryption key (required)

  -cipher         The cipher algorithm (defaults to Crypt::DES)

  -salt           Enables OpenSSL-compatibility. If equal to a value
                    of "1" then causes a random salt to be generated
                    and used to derive the encryption key and IV. Other
                    true values are taken to be the literal salt.

  -iv             The initialization vector (IV)

  -padding        The padding method, one of "standard", "space",
                     "onesandzeroes", or "null". (default "standard")

  -literal_key    If true, the key provided by "key" is used directly
                      for encryption/decryption.  Otherwise the actual
                      key used will be a hash of the provided key.
		      (default false)

  -pcbc           Whether to use the PCBC chaining algorithm rather than
                    the standard CBC algorithm (default false).

  -add_header     Whether to add the salt and IV to the header of the output
                    cipher text.

  -keysize        Force the cipher keysize to the indicated number of bytes.

  -blocksize      Force the cipher blocksize to the indicated number of bytes.

  -legacy_iv      Use (broken) IV length of 8 bytes, rather than correct length
                   of blocksize bytes.

  -regenerate_key [deprecated; use literal_key instead]
                  Whether to use a hash of the provided key to generate
                    the actual encryption key (default true)

  -prepend_iv     [deprecated; use add_header instead]
                  Whether to prepend the IV to the beginning of the
                    encrypted stream (default true)

You must provide an encryption/decryption B<-key>, which can be any
series of characters of any length. By default, the value you pass as
-key will be used to derive the true key by using a series of MD5
hashes (i.e. the value is used as a passphrase). However, if you pass
a true value for the B<-literal_key> flag, then the actual binary bits
of the value you pass to -key will be used as the encryption key. In
this case, you should choose a key of length exactly equal to the
cipher's key length.

The B<-cipher> option specifies which block cipher algorithm to use to
encode each section of the message.  This argument is optional and
will default to the quick-but-not-very-secure DES algorithm unless
specified otherwise. You may use any compatible block encryption
algorithm that you have installed. Currently, this includes
Crypt::DES, Crypt::DES_EDE3, Crypt::IDEA, Crypt::Blowfish,
Crypt::CAST5 and Crypt::Rijndael. You may refer to them using their
full names ("Crypt::IDEA") or in abbreviated form ("IDEA").

The B<-salt> argument actives an OpenSSL-compatible method of
generating the encryption/decryption key and IV. If salt has the value
"1", then a random salt is computed (highly recommended).  Any other
non-false value will be interpreted as the bytes of the actual salt to
use.  If you provide the salt, it must be exactly 8 bytes in length.
It is highly recommended that you use -salt=>1 as this may become the
default for this module when header generation is active.

The initialization vector (IV) is used to start the CBC chaining
algorithm.  Unless you have also specified a false value for
B<-add_header>, the IV should be exactly blocksize bytes long. The IV
may be specified manually by passing in a key of B<-iv> as an option
to new() or by calling $cipher->set_initialization_vector($iv) before
calling $cipher->start().  If no IV is specified, then one will be
generated randomly for you.  This is backwardly compatible with CBC
encrypted streams generated by the older SSLEay library.

The B<-padding> argument controls how the last few bytes of the
encrypted stream are dealt with when they not an exact multiple of the
cipher block length. The default is "standard", the method specified
in PKCS#5.

The B<-pcbc> argument, if true, activates a modified chaining mode
known as PCBC. It provides better error propagation characteristics
than the default CBC encryption and is required for authenticating to
Kerberos4 systems (see RFC 2222).

The B<-keysize> and B<-blocksize> arguments can be used to force the
cipher's keysize and/or blocksize. This is only currently useful for
the Crypt::Blowfish module, which accepts a variable length
keysize. If -keysize is not specified, then Crypt::CBC will use the
maximum length Blowfish key size of 56 bytes (448 bits). The Openssl
library defaults to 16 byte Blowfish key sizes, so for compatibility
with Openssl you may wish to set -keysize=>16. There are currently no
Crypt::* modules that have variable block sizes, but an option to
change it is provided just in case.

When generating ciphertext, the IV or salt are inserted into the
encrypted data as a 16 byte header. If the B<-salt> option was
specified, the header will consist of the string "Salted__" followed
by 8 bytes of salt data. Otherwise the header will consist of
"RandomIV" followed by 8 bytes of IV data. During decryption, if the
ciphertext is found to contain either of these headers, the IV or salt
will be retrieved and used during the decryption process, ignoring any
values that you might have set manually.

You may disable the generation of the encryption header by passing a
false value to B<-add_header>.  You must provide an explicit -iv value
and must B<not> use -salt=>1 when operating in this mode. The same
values for -iv and -salt (if used) must be used for both encryption
and decryption.

For compatibility with earlier versions of this module, you can
provide new() with a hashref containing key/value pairs. The key names
are the same as the arguments described earlier, but without the
initial hyphen.  You may also call new() with one or two positional
arguments, in which case the first argument is taken to be the key and
the second to be the optional block cipher algorithm.

IMPORTANT NOTE: Versions of this module prior to 2.17 were incorrectly
using 8 byte IVs when generating the old-style RandomIV style header
(as opposed to the new-style random salt header). This affects the
Rijndael algorithm, which has a 16 byte blocksize. The bug has been
corrected in versions 2.17 and higher, but in order to read legacy
encrypted data, you will have to pass the B<-legacy_iv> option to
new() using a true value.

=head2 start()

   $cipher->start('encrypting');
   $cipher->start('decrypting');

The start() method prepares the cipher for a series of encryption or
decryption steps, resetting the internal state of the cipher if
necessary.  You must provide a string indicating whether you wish to
encrypt or decrypt.  "E" or any word that begins with an "e" indicates
encryption.  "D" or any word that begins with a "d" indicates
decryption.

=head2 crypt()
 
   $ciphertext = $cipher->crypt($plaintext);

After calling start(), you should call crypt() as many times as
necessary to encrypt the desired data.  

=head2  finish()

   $ciphertext = $cipher->finish();

The CBC algorithm must buffer data blocks inernally until they are
even multiples of the encryption algorithm's blocksize (typically 8
bytes).  After the last call to crypt() you should call finish().
This flushes the internal buffer and returns any leftover ciphertext.

In a typical application you will read the plaintext from a file or
input stream and write the result to standard output in a loop that
might look like this:

  $cipher = new Crypt::CBC('hey jude!');
  $cipher->start('encrypting');
  print $cipher->crypt($_) while <>;
  print $cipher->finish();

=head2 encrypt()

  $ciphertext = $cipher->encrypt($plaintext)

This convenience function runs the entire sequence of start(), crypt()
and finish() for you, processing the provided plaintext and returning
the corresponding ciphertext.

=head2 decrypt()

  $plaintext = $cipher->decrypt($ciphertext)

This convenience function runs the entire sequence of start(), crypt()
and finish() for you, processing the provided ciphertext and returning
the corresponding plaintext.

=head2 encrypt_hex(), decrypt_hex()

  $ciphertext = $cipher->encrypt_hex($plaintext)
  $plaintext  = $cipher->decrypt_hex($ciphertext)

These are convenience functions that operate on ciphertext in a
hexadecimal representation.  B<encrypt_hex($plaintext)> is exactly
equivalent to B<unpack('H*',encrypt($plaintext))>.  These functions
can be useful if, for example, you wish to place the encrypted in an
email message.

=head2 get_initialization_vector()

  $iv = $cipher->get_initialization_vector()

This function will return the IV used in encryption and or decryption.
The IV is not guaranteed to be set when encrypting until start() is
called, and when decrypting until crypt() is called the first time.

=head2 set_initialization_vector()

  $cipher->set_initialization_vector('76543210')

This function sets the IV used in encryption and/or decryption. This
function may be useful if the IV is not contained within the
ciphertext string being decrypted, or if a particular IV is desired
for encryption.  Note that the IV must be the chosen cipher's
blocksize bytes in length.

=head2 iv()

  $iv = $cipher->iv();
  $cipher->iv($new_iv);

As above, but using a single method call.

=head2 key()

  $key = $cipher->key();
  $cipher->key($new_key);

Get or set the actual key used for encryption/decryption.  When
encrypting, the key is not guaranteed to exist until start() is
called, and when decrypting, the key is not guaranteed to exist until
after the first call to crypt(). The key must match the length
required by the underlying block cipher.

=head2 salt()

  $salt = $cipher->salt();
  $cipher->salt($new_salt);

Get or set the salt used for deriving the encryption key and IV when
in OpenSSL compatibility mode.

=head2 passphrase()

  $passphrase = $cipher->passphrase();
  $cipher->passphrase($new_passphrase);

This gets or sets the value of the B<key> passed to new() when
B<literal_key> is false.

=head2 cipher(), padding(), keysize(), blocksize(), pcbc()

These read-only methods return the identity of the chosen block cipher
algorithm, padding method, key and block size of the chosen block
cipher, and whether PCBC chaining is in effect.

=head2 Padding methods

Use the 'padding' option to change the padding method.

When the last block of plaintext is shorter than the block size,
it must be padded. Padding methods include: "standard" (i.e., PKCS#5),
"oneandzeroes", "space", and "null".

   standard: (default) Binary safe
      pads with the number of bytes that should be truncated. So, if 
      blocksize is 8, then "0A0B0C" will be padded with "05", resulting
      in "0A0B0C0505050505". If the final block is a full block of 8 
      bytes, then a whole block of "0808080808080808" is appended.

   oneandzeroes: Binary safe
      pads with "80" followed by as many "00" necessary to fill the
      block. If the last block is a full block and blocksize is 8, a
      block of "8000000000000000" will be appended.

   null: text only
      pads with as many "00" necessary to fill the block. If the last 
      block is a full block and blocksize is 8, a block of 
      "0000000000000000" will be appended.

   space: text only
      same as "null", but with "20".
      
Both the standard and oneandzeroes paddings are binary safe.  The
space and null paddings are recommended only for text data.  Which
type of padding you use depends on whether you wish to communicate
with an external (non Crypt::CBC library).  If this is the case, use
whatever padding method is compatible.

You can also pass in a custom padding function.  To do this, create a
function that takes the arguments:

   $padded_block = function($block,$blocksize,$direction);

where $block is the current block of data, $blocksize is the size to
pad it to, $direction is "e" for encrypting and "d" for decrypting,
and $padded_block is the result after padding or depadding.

When encrypting, the function should always return a string of
<blocksize> length, and when decrypting, can expect the string coming
in to always be that length. See _standard_padding(), _space_padding(),
_null_padding(), or _oneandzeroes_padding() in the source for examples.

Standard and oneandzeroes padding are recommended, as both space and
null padding can potentially truncate more characters than they should. 

=head1 EXAMPLES

Two examples, des.pl and idea.pl can be found in the eg/ subdirectory
of the Crypt-CBC distribution.  These implement command-line DES and
IDEA encryption algorithms.

=head1 LIMITATIONS

The encryption and decryption process is about a tenth the speed of
the equivalent SSLeay programs (compiled C).  This could be improved
by implementing this module in C.  It may also be worthwhile to
optimize the DES and IDEA block algorithms further.

=head1 BUGS

Please report them.

=head1 AUTHOR

Lincoln Stein, lstein@cshl.org

This module is distributed under the ARTISTIC LICENSE using the same
terms as Perl itself.

=head1 SEE ALSO

perl(1), Crypt::DES(3), Crypt::IDEA(3), rfc2898 (PKCS#5)

=cut
